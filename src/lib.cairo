pub mod utilities;
pub mod datastructures;
pub mod constants;
pub mod mock_erc20;

use datastructures::Price;
use starknet::{ContractAddress, ClassHash};

#[starknet::interface]
pub trait IMyCode<TContractState> {
    fn deposit(ref self: TContractState, token: ContractAddress, amount: u256);
    fn withdraw(ref self: TContractState, token: ContractAddress, amount: u256);
    
    fn make_lend_offer(ref self: TContractState, token: ContractAddress, amount: u256, accepted_collateral: u256, price: Price);
    fn disable_lend_offer(ref self: TContractState, id_offer: u64);
    fn make_borrow_offer(ref self: TContractState, token: ContractAddress, amount: u256, price: Price);
    fn disable_borrow_offer(ref self: TContractState, id_offer: u64);

    fn match_offer(ref self: TContractState, lend_offer_id: u64, borrow_offer_id: u64, amount: u256);
    fn repay_offer(ref self: TContractState, offer_id: u64);
    fn liquidate_offer(ref self: TContractState, offer_id: u64);

    // Admin
    fn upgrade(ref self: TContractState, new_class_hash: ClassHash);
    fn add_asset(ref self: TContractState, asset: ContractAddress, category: felt252, is_lend_asset: bool, price: u256, ltv: u256);
    fn add_user_point(ref self: TContractState, user: ContractAddress, amount: u256);

    // Getters
    fn balanceOf(ref self: TContractState, user: ContractAddress, asset: ContractAddress) -> u256;
}

#[starknet::contract]
pub mod MyCode {
    use super::constants;
    use super::mock_erc20::{ IERC20Dispatcher, IERC20DispatcherTrait };
    // Our structures
    use fixedlend::datastructures::{ LendingOffer, BorrowingOffer, Price, Match };
    // Utilities
    use fixedlend::utilities::{ assert_is_admin, assert_validity_of_price,
        interest_to_repay, max_to_repay, max2, min2, to_assets_decimals };
    // Starknet
    use starknet::{ ContractAddress, ClassHash, syscalls::replace_class_syscall, get_caller_address, get_contract_address, get_block_timestamp };
    use starknet::storage::{ StoragePointerReadAccess, StoragePointerWriteAccess, StoragePathEntry };
    use starknet::storage::{ Map, StorageMapReadAccess, StorageMapWriteAccess, Vec, MutableVecTrait };

    #[storage]
    struct Storage {
        // Informations about users
        assets_user: Map<ContractAddress, Map<ContractAddress, u256>>, // User => (Asset => quantity)
        lend_offers: Vec<LendingOffer>,
        borrow_offers: Vec<BorrowingOffer>,
        current_matches: Vec<Match>,

        // Informations about assets
        category_information: Map<ContractAddress, felt252>, // Which asset is of which category
        assets_lender: Map<ContractAddress, bool>,           // Assets accepted to be lent
        assets_borrower: Map<ContractAddress, bool>,         // Assets accepted to borrow with
        price_information: Map<ContractAddress, u256>,       // Price of assets - see integration.cairo for more info
        ltv_information: Map<ContractAddress, u256>,         // Loan To Value info about assets - see integration.cairo

        // Points
        points_multiplier: u256,
        total_points: u256,
        user_points: Map<ContractAddress, u256>,
        points_multiplier_per_asset: Map<ContractAddress, u256>,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {}

    // First some non public functions, and then the implementation of the interface
    fn compute_value_of_asset(self: @ContractState, amount: u256, address: ContractAddress) -> u256 {
        let price = self.price_information.read(address);
        let ltv = self.ltv_information.read(address);
        let amount = amount * price * ltv / constants::LTV_SCALE;
        amount / constants::VALUE_1e18 // price_of_assets it scaled to 10**18, that's why we divide by 10**18
    }

    // Private function
    fn increase_user_point(ref self: ContractState, user: ContractAddress, amount: u256, asset: ContractAddress) {
        let user_point = self.user_points.entry(user).read();
        let amount = amount * self.points_multiplier_per_asset.entry(asset).read();
        let amount = amount * self.points_multiplier.read();
        self.user_points.entry(user).write(user_point + amount);
        self.total_points.write(self.total_points.read() + amount);
    }

    // The real code of the contract start here
    #[abi(embed_v0)]
    impl MyCodeImpl of super::IMyCode<ContractState> {

        // @dev: amount in 10**18 decimals
        fn deposit(ref self: ContractState, token: ContractAddress, amount: u256) {
            assert!(self.category_information.read(token) != 0, "This token cannot be lent nor be used as a colletaral");
            let caller = get_caller_address();
            let mut current_deposit = self.assets_user.entry(caller).read(token);
            current_deposit += amount;
            self.assets_user.entry(caller).write(token, current_deposit);
            let erc20 = IERC20Dispatcher { contract_address: token };
            let contract = get_contract_address();
            let amount = to_assets_decimals(token, amount);
            assert!(erc20.allowance(caller, contract) >= amount, "Not enough allowance to make this deposit");
            erc20.transferFrom(caller, contract, amount);
        }

        // @dev: amount in 10**18 decimals
        fn withdraw(ref self: ContractState, token: ContractAddress, amount: u256) {
            assert!(self.category_information.read(token) != 0, "This token cannot be lent nor be used as a colletaral");
            let caller = get_caller_address();
            let mut current_deposit = self.assets_user.entry(caller).read(token);
            assert!(current_deposit >= amount, "Not enough balance to withdraw");
            current_deposit -= amount;
            self.assets_user.entry(caller).write(token, current_deposit);
            let erc20 = IERC20Dispatcher { contract_address: token };
            erc20.transfer(caller, to_assets_decimals(token, amount));
        }

        // @dev: amount is in 10**18 scale
        fn make_lend_offer(ref self: ContractState, token: ContractAddress, amount: u256, accepted_collateral: u256, price: Price) {
            assert!(self.category_information.read(token) != 0, "This token has no category - so cannot be lent");
            assert!(self.assets_lender.read(token), "This token cannot be lent");
            assert_validity_of_price(price);
            let caller = get_caller_address();
            
            let lend_offer = LendingOffer {
                id: self.lend_offers.len(),
                is_active: true,
                proposer: caller,
                token,
                total_amount: amount,
                amount_available: amount,
                price,
                accepted_collateral,
            };

            self.lend_offers.push(lend_offer);
        }

        fn disable_lend_offer(ref self: ContractState, id_offer: u64) {
            let caller = get_caller_address();
            assert!(caller == self.lend_offers.at(id_offer).read().proposer, "You can only disable your own lending offer");
            let mut lend_offer = self.lend_offers.at(id_offer).read();
            assert!(lend_offer.is_active, "The lending offer is already disabled");
            lend_offer.is_active = false;
            self.lend_offers.at(id_offer).write(lend_offer);
        }

        fn make_borrow_offer(ref self: ContractState, token: ContractAddress, amount: u256, price: Price) {
            assert!(self.category_information.read(token) != 0, "This token has no category - so cannot be used as a collateral");
            assert!(self.assets_borrower.read(token), "This token is not a borrow asset");
            assert_validity_of_price(price);
            let caller = get_caller_address();
            
            let borrow_offer = BorrowingOffer {
                id: self.borrow_offers.len(),
                is_active: true,
                proposer: caller,
                total_amount: amount,
                amount_available: amount,
                price,
                token_collateral: token,
                amount_collateral: amount
            };

            self.borrow_offers.push(borrow_offer);
        }

        fn disable_borrow_offer(ref self: ContractState, id_offer: u64) {
            let caller = get_caller_address();
            assert!(caller == self.borrow_offers.at(id_offer).read().proposer, "You can only disable your own borrowing offer");
            let mut borrow_offer = self.borrow_offers.at(id_offer).read();
            assert!(borrow_offer.is_active, "The borrowing offer is already disabled");
            borrow_offer.is_active = false;
            self.borrow_offers.at(id_offer).write(borrow_offer);
        }

        fn match_offer(ref self: ContractState, lend_offer_id: u64, borrow_offer_id: u64, amount: u256) {
            let mut lend_offer = self.lend_offers.at(lend_offer_id).read();
            let lender = lend_offer.proposer;
            let lend_token = lend_offer.token;

            let mut borrow_offer = self.borrow_offers.at(lend_offer_id).read();
            let borrower = borrow_offer.proposer;
            let borrow_token = borrow_offer.token_collateral;

            // Check: Both offer are still active
            assert!(lend_offer.is_active, "The lending offer is not active");
            assert!(borrow_offer.is_active, "The borrowing offer is not active");
            // Check: Both assets are in the same category
            assert!(self.category_information.read(lend_offer.token) == self.category_information.read(borrow_offer.token_collateral),
                "The assets are not in the same category, the match can't be made");
            // Check: The APR is good
            assert!(borrow_offer.price.rate >= constants::APR_1_PERCENT + lend_offer.price.rate,
                "Offer price are not compatible, you need borrow_rate - lending_rate >= 1percent (platform fee)");
            // Check: amount is not too large
            assert!(amount <= lend_offer.amount_available, "Not enough demand available in the lend offer");
            assert!(amount <= borrow_offer.amount_available, "Not enough demand available in the borrow offer");
            // Create a new match
            let price_match = Price {
                rate: lend_offer.price.rate,
                // More flexibility for the borrower to do that instead of max2(lending.min, borrower.min)
                // And it's essentially the same because it's the borrower that choose to repay, not the lender
                // Todo, now it's max2 but let do something better in the future
                minimal_duration: max2(lend_offer.price.minimal_duration, borrow_offer.price.minimal_duration),
                // This give less flexibility to the borrower, but takes less of its collateral
                // as the amount of collateral is based on the maximal length of the loan
                // A taker borrower is therefore free to choose whatever value he prefers for this min
                // And a maker borrower needs to be careful because this duration can be choosen arbitraly small
                maximal_duration: min2(lend_offer.price.maximal_duration, borrow_offer.price.maximal_duration)
            };
            assert_validity_of_price(price_match);

            let current_date = get_block_timestamp();
            let new_match = Match {
                id: self.current_matches.len(),
                is_active: true,
                lend_offer_id: lend_offer.id,
                borrow_offer_id: borrow_offer.id,
                amount: amount,
                lending_rate: lend_offer.price.rate,
                date_taken: current_date,
                borrowing_rate: borrow_offer.price.rate,
                minimal_duration: price_match.minimal_duration,
                maximal_duration: price_match.maximal_duration
            };
            let max_to_repay = max_to_repay(new_match);
            // Check: The lender has enough asset to lend
            assert!(self.assets_user.entry(lend_offer.proposer).read(lend_token) >= amount, 
                "The lender did not deposit enough asset to lend for this offer");
            // Check: The borrower has enough collateral
            assert!(self.assets_user.entry(borrow_offer.proposer).read(borrow_token) >= max_to_repay, 
                "The borrower did not deposit enough collateral for this offer");
            self.current_matches.push(new_match);

            // Update the offers
            lend_offer.amount_available -= amount;
            self.lend_offers.at(lend_offer_id).write(lend_offer);
            borrow_offer.amount_available -= amount;
            self.borrow_offers.at(borrow_offer_id).write(borrow_offer);
            
            // Update the amount each user has on the protocol
            // Transfer the assets
            let lender_balance = self.assets_user.entry(lender).read(lend_token);
            self.assets_user.entry(lender).write(lend_token, lender_balance - amount);
            let borrow_lend_balance = self.assets_user.entry(borrower).read(lend_token);
            self.assets_user.entry(borrower).write(lend_token, borrow_lend_balance + amount);
            // Substract the collateral from borrower account
            let borrower_balance = self.assets_user.entry(borrower).read(borrow_token);
            self.assets_user.entry(borrower).write(borrow_token, borrower_balance - max_to_repay);
        }
        
        fn repay_offer(ref self: ContractState, offer_id: u64) {
            let mut match_offer = self.current_matches.at(offer_id).read();
            let amount = match_offer.amount;
            let lend_offer_id = match_offer.lend_offer_id;
            let borrow_offer_id = match_offer.borrow_offer_id;

            let mut lend_offer = self.lend_offers.at(lend_offer_id).read();
            let lender = lend_offer.proposer;
            let lend_token = lend_offer.token;

            let mut borrow_offer = self.borrow_offers.at(borrow_offer_id).read();
            let borrower = borrow_offer.proposer;
            let borrow_token = borrow_offer.token_collateral;
            assert!(get_caller_address() == borrower, "Only the borrower can repay its debt");

            // Check: The match is still active
            assert!(match_offer.is_active, "This offer is no longer active");

            // Check: We are within repay time
            let current_time = get_block_timestamp();
            assert!(current_time >= match_offer.date_taken + match_offer.minimal_duration,
                "You cannot repay the lend this early wait for the minimal time");
            assert!(current_time <= match_offer.date_taken + match_offer.maximal_duration,
                "It is too late to repay this offer please liquidate instead");

            let (interest_lender, fee) = interest_to_repay(match_offer, current_time);
            let borrower_balance = self.assets_user.entry(borrower).read(lend_token);
            assert!(borrower_balance >= amount + interest_lender + fee, "Not enough balance to repay the offer");
            self.assets_user.entry(borrower).write(lend_token, borrower_balance - amount - interest_lender - fee);
            let lender_balance = self.assets_user.entry(lender).read(lend_token);
            self.assets_user.entry(lender).write(lend_token, lender_balance + amount + interest_lender);
            let contract_address = get_contract_address();
            let contract_balance = self.assets_user.entry(contract_address).read(lend_token);
            self.assets_user.entry(contract_address).write(lend_token, contract_balance + fee);
            // Give back the collateral to the borrower
            let borrower_balance = self.assets_user.entry(borrower).read(borrow_token);
            self.assets_user.entry(borrower).write(borrow_token, borrower_balance + max_to_repay(match_offer));

            match_offer.is_active = false;
            self.current_matches.at(offer_id).write(match_offer);

            let total_amount = amount + interest_lender + fee;
            increase_user_point(ref self, lender, total_amount, lend_token);
            increase_user_point(ref self, borrower, total_amount, lend_token);

            lend_offer.amount_available += amount;
            self.lend_offers.at(lend_offer_id).write(lend_offer);
            borrow_offer.amount_available += amount;
            self.borrow_offers.at(borrow_offer_id).write(borrow_offer);
        }

        fn liquidate_offer(ref self: ContractState, offer_id: u64) {
            let mut match_offer = self.current_matches.at(offer_id).read();
            let amount = match_offer.amount;
            let lend_offer_id = match_offer.lend_offer_id;
            let borrow_offer_id = match_offer.borrow_offer_id;

            let mut lend_offer = self.lend_offers.at(lend_offer_id).read();
            let lender = lend_offer.proposer;
            let lend_token = lend_offer.token;

            let mut borrow_offer = self.borrow_offers.at(borrow_offer_id).read();
            let borrower = borrow_offer.proposer;
            let borrow_token = borrow_offer.token_collateral;

            // Check: The match is still active
            assert!(match_offer.is_active, "This offer is no longer active");

            // Check: We are within liquidation time
            let current_time = get_block_timestamp();
            assert!(current_time >= match_offer.date_taken + match_offer.maximal_duration,
                "You cannot liquidation this early wait for the maximal time");

            // Check if borrower can still repay with its balance
            let (interest_lender, fee) = interest_to_repay(match_offer, current_time);
            let borrower_balance = self.assets_user.entry(borrower).read(lend_token);
            if borrower_balance >= amount + interest_lender + fee {
                // Repay with balance of borrower
                let lender_balance = self.assets_user.entry(lender).read(lend_token);
                self.assets_user.entry(lender).write(lend_token, lender_balance + amount + interest_lender + fee);
                let borrower_balance = self.assets_user.entry(borrower).read(lend_token);
                self.assets_user.entry(borrower).write(lend_token, borrower_balance - amount - interest_lender - fee);
            } else {
                // Transfer collateral to user
                let lender_balance = self.assets_user.entry(lender).read(borrow_token);
                self.assets_user.entry(lender).write(borrow_token, lender_balance + max_to_repay(match_offer));
            }
            let total_amount = amount + interest_lender + fee;
            increase_user_point(ref self, lender, total_amount, lend_token);
            match_offer.is_active = false;
            self.current_matches.at(offer_id).write(match_offer);
            // We don't increase back the lend/borrow offer available amount
        }

        // Admin
        fn upgrade(ref self: ContractState, new_class_hash: ClassHash) {
            assert_is_admin();
            replace_class_syscall(new_class_hash).unwrap();
        }
        fn add_asset(ref self: ContractState, asset: ContractAddress, category: felt252, is_lend_asset: bool, price: u256, ltv: u256) {
            assert_is_admin();
            self.category_information.write(asset, category);
            if is_lend_asset {
                self.assets_lender.write(asset, true);
            } else {
                self.assets_borrower.write(asset, true);
                self.ltv_information.write(asset, ltv);
            }
            self.price_information.write(asset, price);
        }
        fn add_user_point(ref self: ContractState, user: ContractAddress, amount: u256) {
            self.user_points.entry(user).write(self.user_points.entry(user).read() + amount);
        }

        // Getters
        fn balanceOf(ref self: ContractState, user: ContractAddress, asset: ContractAddress) -> u256 {
            assert!(self.category_information.read(asset) != 0, "This token has no category ");
            self.assets_user.entry(user).read(asset)
        }
    }
}