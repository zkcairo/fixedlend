pub mod utilities;
pub mod datastructures;
pub mod constants;
pub mod mock_erc20;

use datastructures::{LendOffer, BorrowOffer, Price, Match};
use starknet::{ContractAddress, ClassHash};

// Only this part is in audit scope
#[starknet::interface]
pub trait IMyCode<TContractState> {
    // Deposit/Withdraw
    fn deposit(ref self: TContractState, token: ContractAddress, amount: u256);
    fn withdraw(ref self: TContractState, token: ContractAddress, amount: u256);
    fn withdraw_protocol_fee(ref self: TContractState, token: ContractAddress, amount: u256);
    
    // Make/Disable offers
    fn make_lend_offer(ref self: TContractState, token: ContractAddress, amount: u256, accepted_collateral: u256, price: Price);
    fn disable_lend_offer(ref self: TContractState, id_offer: u64);
    fn make_borrow_offer(ref self: TContractState, token: ContractAddress, amount: u256, price: Price);
    fn disable_borrow_offer(ref self: TContractState, id_offer: u64);

    // Match, Repay, and Liquidate offers
    fn match_offer(ref self: TContractState, lend_offer_id: u64, borrow_offer_id: u64, amount: u256);
    fn repay_offer(ref self: TContractState, offer_id: u64);
    fn liquidate_offer(ref self: TContractState, offer_id: u64);

    // Admin
    fn upgrade(ref self: TContractState, new_class_hash: ClassHash);
    fn add_asset(ref self: TContractState, asset: ContractAddress, category: felt252, is_lend_asset: bool, price: u256, ltv: u256, points_multiplier: u256);
    fn set_asset(ref self: TContractState, asset: ContractAddress, price: u256, ltv: u256, points_multiplier: u256);
    fn remove_asset(ref self: TContractState, asset: ContractAddress);
    fn add_user_point(ref self: TContractState, user: ContractAddress, amount: u256);
    fn set_points_multiplier(ref self: TContractState, value: u256);

    // Getters
    fn balanceOf(self: @TContractState, user: ContractAddress, asset: ContractAddress) -> u256;
}

// Frontend functions - all read only - only used in the frontend, never in the contract code - not in audit scope
#[starknet::interface]
pub trait IFrontend<TContractState> {
    // Helper
    fn frontend_actual_lending_amount(self: @TContractState, offer_id: u64) -> u256;
    fn frontend_actual_borrowing_amount(self: @TContractState, offer_id: u64) -> u256;
    // UX
    fn frontend_get_all_offers(self: @TContractState, category: felt252) -> (Span<BorrowOffer>, Span<LendOffer>);
    // Frontpage
    fn frontend_best_available_yield(self: @TContractState, category: felt252) -> (u256, u256);
    fn frontend_available_to_lend_and_borrow(self: @TContractState, category: felt252) -> (u256, u256);
    fn frontend_get_lend_offers_of_user(self: @TContractState, category: felt252, user: ContractAddress) -> Span<LendOffer>;
    fn frontend_get_borrow_offers_of_user(self: @TContractState, category: felt252, user: ContractAddress) -> Span<BorrowOffer>;
    fn frontend_get_all_matches_of_user(self: @TContractState, category: felt252, user: ContractAddress) -> (Span<(Match, ContractAddress)>, Span<(Match, ContractAddress)>);
    // Helpers
    fn frontend_all_lend_offers_len(self: @TContractState) -> u64;
    fn frontend_all_borrow_offers_len(self: @TContractState) -> u64;
    fn frontend_get_ltv(self: @TContractState, token: ContractAddress) -> u256;
    fn frontend_needed_amount_of_collateral(self: @TContractState, token: ContractAddress, amount: u256, maximal_duration: u64, rate: u256) -> u256;
    // Points
    fn frontend_get_user_points(self: @TContractState, user: ContractAddress) -> u256;
    fn frontend_get_total_points(self: @TContractState) -> u256;
}

#[starknet::contract]
pub mod MyCode {
    use super::constants;
    use super::mock_erc20::{ IERC20Dispatcher, IERC20DispatcherTrait };
    // Our structures
    use fixedlend::datastructures::{ LendOffer, BorrowOffer, Price, Match };
    // Utilities
    use fixedlend::utilities::{ assert_is_admin, assert_validity_of_price,
        interest_to_repay, max_to_repay, max2, min2, compute_interest, to_assets_decimals, value_of_asset, inverse_value_of_asset };
    // Starknet
    use starknet::{ ContractAddress, ClassHash, syscalls::replace_class_syscall, get_caller_address, get_contract_address, get_block_timestamp };
    use starknet::storage::{ StoragePointerReadAccess, StoragePointerWriteAccess, StoragePathEntry };
    use starknet::storage::{ Map, StorageMapReadAccess, StorageMapWriteAccess, Vec, VecTrait, MutableVecTrait };

    #[storage]
    struct Storage {
        // Informations about users
        assets_user: Map<ContractAddress, Map<ContractAddress, u256>>, // User => (Asset => quantity)
        lend_offers: Vec<LendOffer>,
        borrow_offers: Vec<BorrowOffer>,
        current_matches: Vec<Match>,

        // Informations about assets
        category_information: Map<ContractAddress, felt252>, // Which asset is of which category
        assets_lender: Map<ContractAddress, bool>,           // Assets accepted to be lent
        assets_borrower: Map<ContractAddress, bool>,         // Assets accepted to borrow with
        price_information: Map<ContractAddress, u256>,       // Price of assets - used in utilities.cairo/inverse_value_of_asset
        ltv_information: Map<ContractAddress, u256>,         // Loan To Value info about assets - used too in inverse_value_of_asset

        // Points
        points_multiplier: u256,
        total_points: u256,
        user_points: Map<ContractAddress, u256>,
        points_multiplier_per_asset: Map<ContractAddress, u256>,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {}

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
            let caller = get_caller_address();
            let mut current_deposit = self.assets_user.entry(caller).read(token);
            current_deposit += amount;
            self.assets_user.entry(caller).write(token, current_deposit);
            let erc20 = IERC20Dispatcher { contract_address: token };
            let contract = get_contract_address();
            let amount_asset = to_assets_decimals(token, amount);
            assert!(erc20.allowance(caller, contract) >= amount_asset, "Not enough allowance to make this deposit");
            erc20.transferFrom(caller, contract, amount_asset);
        }

        // @dev: amount in 10**18 decimals
        fn withdraw(ref self: ContractState, token: ContractAddress, amount: u256) {
            let caller = get_caller_address();
            let mut current_deposit = self.assets_user.entry(caller).read(token);
            assert!(current_deposit >= amount, "Not enough balance to withdraw");
            current_deposit -= amount;
            self.assets_user.entry(caller).write(token, current_deposit);
            let erc20 = IERC20Dispatcher { contract_address: token };
            let amount_asset = to_assets_decimals(token, amount);
            erc20.transfer(caller, amount_asset);
        }
        fn withdraw_protocol_fee(ref self: ContractState, token: ContractAddress, amount: u256) {
            assert_is_admin();
            // Yes, get_contract_address() is not the caller, we just keep the same variable name so we can see it's exactly the same function as above
            // until the very last line, where we transfer the money to the caller (the admin address)
            let caller = get_contract_address();
            let mut current_deposit = self.assets_user.entry(caller).read(token);
            assert!(current_deposit >= amount, "Not enough balance to withdraw");
            current_deposit -= amount;
            self.assets_user.entry(caller).write(token, current_deposit);
            let erc20 = IERC20Dispatcher { contract_address: token };
            let amount_asset = to_assets_decimals(token, amount);
            erc20.transfer(get_caller_address(), amount_asset);
        }

        // @dev: amount is in 10**18 scale
        fn make_lend_offer(ref self: ContractState, token: ContractAddress, amount: u256, accepted_collateral: u256, price: Price) {
            assert!(self.category_information.read(token) != 0, "This token is disabled, no new offer with it can be made");
            assert!(self.assets_lender.read(token), "This token cannot be lent");
            assert!(price.rate % constants::APR_01_PERCENT == 0, "APR must be modulo 0 of 0.1% apr (aka 5.1% is ok but 5.12% is not)");
            assert_validity_of_price(price);
            let caller = get_caller_address();
            
            let lend_offer = LendOffer {
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
            assert!(self.category_information.read(token) != 0, "This token is disabled, no new offer with it can be made");
            assert!(self.assets_borrower.read(token), "This token is not a borrow asset");
            assert!(price.rate % constants::APR_01_PERCENT == 0, "APR must be modulo 0 of 0.1% apr (aka 5.1% is ok but 5.12% is not)");
            assert_validity_of_price(price);
            let caller = get_caller_address();
            
            let borrow_offer = BorrowOffer {
                id: self.borrow_offers.len(),
                is_active: true,
                proposer: caller,
                total_amount: amount,
                amount_available: amount,
                price,
                token_collateral: token,
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

            let mut borrow_offer = self.borrow_offers.at(borrow_offer_id).read();
            let borrower = borrow_offer.proposer;
            let borrow_token = borrow_offer.token_collateral;

            // Check: Both offer are still active
            assert!(lend_offer.is_active, "The lending offer is not active");
            assert!(borrow_offer.is_active, "The borrowing offer is not active");
            // Check: Both assets are in the same category
            let category_lend = self.category_information.read(lend_offer.token);
            let category_borrow = self.category_information.read(borrow_offer.token_collateral);
            assert!(category_lend != 0, "The lending asset is disabled");
            assert!(category_borrow != 0, "The borrowing asset is disabled");
            assert!(category_lend == category_borrow,
                "The assets are not in the same category, the match can't be made");
            // Check: The APR is good
            assert!(borrow_offer.price.rate >= lend_offer.price.rate + constants::APR_PROTOCOL_FEE,
                "Offer price are not compatible, you need borrow_rate >= lending_rate + platform fee");
            // Check: amount is not too large
            assert!(amount <= lend_offer.amount_available, "Not enough demand available in the lend offer");
            assert!(amount <= borrow_offer.amount_available, "Not enough demand available in the borrow offer");
            // Create a new match
            // The choice of using max2 and min2 is discussed in the docs.
            let price_match = Price {
                rate: lend_offer.price.rate,
                minimal_duration: max2(lend_offer.price.minimal_duration, borrow_offer.price.minimal_duration),
                maximal_duration: min2(lend_offer.price.maximal_duration, borrow_offer.price.maximal_duration)
            };
            assert_validity_of_price(price_match);

            let current_date = get_block_timestamp();
            
            let mut new_match = Match {
                id: self.current_matches.len(),
                is_active: true,
                lend_offer_id: lend_offer.id,
                borrow_offer_id: borrow_offer.id,
                amount: amount,
                amount_collateral: 0, // Filled just below
                lending_rate: price_match.rate,
                date_taken: current_date,
                // price_match.rate + constants::APR_PROTOCOL_FEE is better for the borrower than borrow_offer.price.rate
                borrowing_rate: price_match.rate + constants::APR_PROTOCOL_FEE, // Platform fee
                minimal_duration: price_match.minimal_duration,
                maximal_duration: price_match.maximal_duration
            };
            // Check: The lender has enough asset to lend
            assert!(self.assets_user.entry(lend_offer.proposer).read(lend_token) >= amount, 
            "The lender did not deposit enough asset to lend for this offer");
            // Check: The borrower has enough collateral
            let max_to_repay = max_to_repay(new_match);
            let price_collateral = self.price_information.entry(borrow_offer.token_collateral).read();
            let ltv_collateral = self.ltv_information.entry(borrow_offer.token_collateral).read();
            // Essentially, we want value_of_assert(collateral) >= value_of_asset(max_to_repay)
            // Right now, value_of_asset(max_to_repay) is max_to_repay
            // And collateral_amount is inverse_value_of_asset(max_to_repay, price_collateral, ltv_collateral)
            // So the assertion we want is:
            // value_of_assert(inverse_value_of_asset(max_to_repay, price_collateral, ltv_collateral) >= max_to_repay
            // and yeah so these functions are built so that value_of_asset(inverse_value_of_asset(smth)) >= smth
            // (Fuzz tested in test_utilities function check_value_of_collateral)
            // So the assertion we want is always satisfied with this collateral, and we are all good
            let collateral_amount = inverse_value_of_asset(max_to_repay, price_collateral, ltv_collateral);
            assert!(self.assets_user.entry(borrow_offer.proposer).read(borrow_token) >= collateral_amount, 
                "The borrower did not deposit enough collateral for this offer");
            new_match.amount_collateral = collateral_amount;
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
            let borrow_balance_lend = self.assets_user.entry(borrower).read(lend_token);
            self.assets_user.entry(borrower).write(lend_token, borrow_balance_lend + amount);
            // Substract the collateral from borrower account
            let borrower_balance_borrow = self.assets_user.entry(borrower).read(borrow_token);
            self.assets_user.entry(borrower).write(borrow_token, borrower_balance_borrow - collateral_amount);
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
            let borrower_balance_lend = self.assets_user.entry(borrower).read(lend_token);
            assert!(borrower_balance_lend >= amount + interest_lender + fee, "Not enough balance to repay the offer");
            self.assets_user.entry(borrower).write(lend_token, borrower_balance_lend - amount - interest_lender - fee);
            let lender_balance = self.assets_user.entry(lender).read(lend_token);
            self.assets_user.entry(lender).write(lend_token, lender_balance + amount + interest_lender);
            let contract_address = get_contract_address();
            let contract_balance = self.assets_user.entry(contract_address).read(lend_token);
            self.assets_user.entry(contract_address).write(lend_token, contract_balance + fee);
            // Give back the collateral to the borrower
            let borrower_balance_borrow = self.assets_user.entry(borrower).read(borrow_token);
            self.assets_user.entry(borrower).write(borrow_token, borrower_balance_borrow + match_offer.amount_collateral);

            match_offer.is_active = false;
            self.current_matches.at(offer_id).write(match_offer);

            increase_user_point(ref self, lender, fee, lend_token);
            increase_user_point(ref self, borrower, fee, lend_token);

            lend_offer.amount_available += amount + interest_lender; // Auto compound interest
            lend_offer.total_amount += interest_lender;
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
                let borrower_balance_lend = self.assets_user.entry(borrower).read(lend_token);
                self.assets_user.entry(borrower).write(lend_token, borrower_balance_lend - amount - interest_lender - fee);
                let lender_balance = self.assets_user.entry(lender).read(lend_token);
                self.assets_user.entry(lender).write(lend_token, lender_balance + amount + interest_lender);
                let contract_address = get_contract_address();
                let contract_balance = self.assets_user.entry(contract_address).read(lend_token);
                self.assets_user.entry(contract_address).write(lend_token, contract_balance + fee);
                // Give back the collateral to the borrower
                let borrower_balance_borrow = self.assets_user.entry(borrower).read(borrow_token);
                self.assets_user.entry(borrower).write(borrow_token, borrower_balance_borrow + match_offer.amount_collateral);
                // Points
                increase_user_point(ref self, lender, fee, lend_token);
                increase_user_point(ref self, borrower, fee, lend_token);
                // Re-add amount_available to the lend offer
                lend_offer.amount_available += amount + interest_lender; // Auto compound interest
                lend_offer.total_amount += interest_lender;
                self.lend_offers.at(lend_offer_id).write(lend_offer);
                // But we do not re-add amount_available to the borrow offer, as it's probably unexpected
                // for the borrower to be liquidated, probably he forgot, so we don't want to use again his borrow offer
                // (Although we don't disable its borrow offer)
            } else {
                // Transfer collateral to the lender
                let lender_balance = self.assets_user.entry(lender).read(borrow_token);
                self.assets_user.entry(lender).write(borrow_token, lender_balance + match_offer.amount_collateral);
            }            
            match_offer.is_active = false;
            self.current_matches.at(offer_id).write(match_offer);
            // We don't increase back the lend/borrow offer available amount
        }

        // Admin
        fn upgrade(ref self: ContractState, new_class_hash: ClassHash) {
            assert_is_admin();
            replace_class_syscall(new_class_hash).unwrap();
        }
        fn add_asset(ref self: ContractState, asset: ContractAddress, category: felt252, is_lend_asset: bool, price: u256, ltv: u256, points_multiplier: u256) {
            assert_is_admin();
            assert!(self.category_information.read(asset) == 0, "This asset is already enabled");
            self.category_information.write(asset, category);
            if is_lend_asset {
                self.assets_lender.write(asset, true);
            } else {
                self.assets_borrower.write(asset, true);
                self.ltv_information.write(asset, ltv);
            }
            // Right now, this information for lend asset is not used, but maybe in the future so we add it in the storage right now
            self.price_information.write(asset, price);
            self.points_multiplier_per_asset.entry(asset).write(points_multiplier);
        }
        fn set_asset(ref self: ContractState, asset: ContractAddress, price: u256, ltv: u256, points_multiplier: u256) {
            assert_is_admin();
            assert!(self.category_information.read(asset) != 0, "This asset is not enabled yet");
            self.price_information.write(asset, price);
            self.ltv_information.write(asset, ltv);
            self.points_multiplier_per_asset.entry(asset).write(points_multiplier);
        }
        fn remove_asset(ref self: ContractState, asset: ContractAddress) {
            assert_is_admin();
            assert!(self.category_information.read(asset) != 0, "This asset is already disabled");
            self.category_information.write(asset, 0);
            self.assets_lender.write(asset, false);
            self.assets_borrower.write(asset, false);
            self.ltv_information.write(asset, 0);
            self.price_information.write(asset, 0);
            // We don't reset points_multiplier_per_asset to 0, because there might be some loans going throught when we disable the asset
            // And on settlement of this loan, points needs to be accrued with the value of points_multiplier_per_asset
            // However, the rest of the values (price, ltv, ...) we don't use them on settlements of loans
        }
        fn add_user_point(ref self: ContractState, user: ContractAddress, amount: u256) {
            assert_is_admin();
            self.user_points.entry(user).write(self.user_points.entry(user).read() + amount);
        }
        fn set_points_multiplier(ref self: ContractState, value: u256) {
            assert_is_admin();
            self.points_multiplier.write(value);
        }

        // Getters
        fn balanceOf(self: @ContractState, user: ContractAddress, asset: ContractAddress) -> u256 {
            self.assets_user.entry(user).read(asset)
        }
    }

    // After this line everything is out of audit scope - use at your own risk
    // I reserve the right to change all of these functions, including
    // but not only return wrong values, delete them, change their arguments etc... - use them at risk
    // THE BELOW CODE IS NOT TESTED, I reserve the right to change these functions, including
    // but not only return wrong values, delete them, change their arguments etc... - use them at risk
    // THE BELOW CODE IS NOT PART OF ANY AUDIT SCOPE, I decline any responssabilities regarding
    // the eventual correctness of them - use them at risk
    // Thanks
    // Frontend functions - all read only - only used in the frontend, never in the contract code
    fn min2_256(a: u256, b: u256) -> u256 {
        if a >= b { return b; }
        return a;
    }
    #[abi(embed_v0)]
    impl FrontendImpl of super::IFrontend<ContractState> {
        // From an offer, check what the user can actually pay, aka: its balance, and what the offer permits
        fn frontend_actual_lending_amount(self: @ContractState, offer_id: u64) -> u256 {
            let offer: LendOffer = self.lend_offers.at(offer_id).read();
            let value1 = self.assets_user.entry(offer.proposer).read(offer.token);
            let value2 = offer.amount_available;
            min2_256(value1, value2)
        }
        fn frontend_actual_borrowing_amount(self: @ContractState, offer_id: u64) -> u256 {
            let offer = self.borrow_offers.at(offer_id).read();
            let token = offer.token_collateral;
            let value1 = value_of_asset(self.assets_user.entry(offer.proposer).read(token), self.price_information.entry(token).read(), self.ltv_information.entry(token).read());
            let value2 = offer.amount_available;
            return min2_256(value1, value2);
        }
        
        // Return all current and actual offer based on what the user can pay
        fn frontend_get_all_offers(self: @ContractState, category: felt252) -> (Span<BorrowOffer>, Span<LendOffer>) {
            let mut borrowing = array![];
            let mut i_borrowing = 0;
            let borrow_offer_size = self.borrow_offers.len();
            while i_borrowing != borrow_offer_size {
                let mut offer = self.borrow_offers.at(i_borrowing).read();
                if offer.is_active && self.category_information.read(offer.token_collateral) == category {
                    offer.amount_available = self.frontend_actual_borrowing_amount(i_borrowing);
                    borrowing.append(offer);
                }
                i_borrowing += 1;
            };
            let mut lending = array![];
            let mut i_lending = 0;
            let lend_offer_size = self.lend_offers.len();
            while i_lending != lend_offer_size {
                let mut offer = self.lend_offers.at(i_lending).read();
                if offer.is_active && self.category_information.read(offer.token) == category {
                    offer.amount_available = self.frontend_actual_lending_amount(i_lending);
                    lending.append(offer);
                }
                i_lending += 1;
            };
            (borrowing.span(), lending.span())
        }
        // Return (max_borrow_yield, min_lend_yield)
        // Todo filtrer selon la catégorie
        fn frontend_best_available_yield(self: @ContractState, category: felt252) -> (u256, u256) {
            let (all_borrow, all_lend) = self.frontend_get_all_offers(category);
            let mut max_yield_borrow = constants::MIN_APR;
            for borrow_offer in all_borrow {
                if *borrow_offer.price.rate > max_yield_borrow && *borrow_offer.amount_available >= constants::VALUE_1e18/1000 {
                    max_yield_borrow = *borrow_offer.price.rate;
                }
            };
            let mut max_yield_lend = constants::MAX_APR;
            for lend_offer in all_lend {
                if *lend_offer.price.rate < max_yield_lend && *lend_offer.amount_available >= constants::VALUE_1e18/1000 {
                    max_yield_lend = *lend_offer.price.rate;
                }
            };
            (max_yield_borrow, max_yield_lend)
        }
        // Return (sum(available_borrow_volume), sum(available_lend_volume))
        fn frontend_available_to_lend_and_borrow(self: @ContractState, category: felt252) -> (u256, u256) {
            let (all_borrow, all_lend) = self.frontend_get_all_offers(category);
            let mut available_to_borrow = 0;
            for borrow_offer in all_borrow {
                available_to_borrow += self.frontend_actual_borrowing_amount(*borrow_offer.id);
            };
            let mut available_to_lend = 0;
            for lend_offer in all_lend {
                available_to_lend += self.frontend_actual_lending_amount(*lend_offer.id);
            };
            (available_to_borrow, available_to_lend)
        }
        
        fn frontend_get_lend_offers_of_user(self: @ContractState, category: felt252, user: ContractAddress) -> Span<LendOffer> {
            let mut user_lend_offers = array![];
            let lend_offer_size = self.lend_offers.len();
            let mut i_lending = 0;
            while i_lending != lend_offer_size {
                let offer = self.lend_offers.at(i_lending).read();
                if offer.is_active && offer.proposer == user && self.category_information.read(offer.token) == category {
                    user_lend_offers.append(offer);
                }
                i_lending += 1;
            };
            user_lend_offers.span()
        }
        
        fn frontend_get_borrow_offers_of_user(self: @ContractState, category: felt252, user: ContractAddress) -> Span<BorrowOffer> {
            let mut user_borrow_offers = array![];
            let borrow_offer_size = self.borrow_offers.len();
            let mut i_borrowing = 0;
            while i_borrowing != borrow_offer_size {
                let offer = self.borrow_offers.at(i_borrowing).read();
                if offer.is_active && offer.proposer == user && self.category_information.read(offer.token_collateral) == category {
                    user_borrow_offers.append(offer);
                }
                i_borrowing += 1;
            };
            user_borrow_offers.span()
        }
        
        // First return value is loans when we are borrowers - second is lender
        // The second value of each tuple is the token of the loan
        fn frontend_get_all_matches_of_user(self: @ContractState, category: felt252, user: ContractAddress) -> (Span<(Match, ContractAddress)>, Span<(Match, ContractAddress)>) {
            let mut user_matches_borrowing = array![];
            let mut user_matches_lending = array![];
            let match_size = self.current_matches.len();
            let mut i_match = 0;
            while i_match != match_size {
                let match_offer = self.current_matches.at(i_match).read();
                let lend_offer = self.lend_offers.at(match_offer.lend_offer_id).read();
                let borrow_offer = self.borrow_offers.at(match_offer.borrow_offer_id).read();
                if match_offer.is_active && self.category_information.read(lend_offer.token) == category {
                    if borrow_offer.proposer == user {
                        user_matches_borrowing.append((match_offer, lend_offer.token));
                    }
                    if lend_offer.proposer == user {
                        user_matches_lending.append((match_offer, lend_offer.token));
                    }
                }
                i_match += 1;
            };
            (user_matches_borrowing.span(), user_matches_lending.span())
        }

        // Todo prendre category comme argument
        fn frontend_all_lend_offers_len(self: @ContractState) -> u64 {
            self.lend_offers.len()
        }
        fn frontend_all_borrow_offers_len(self: @ContractState) -> u64 {
            self.borrow_offers.len()
        }
        fn frontend_get_ltv(self: @ContractState, token: ContractAddress) -> u256 {
            self.ltv_information.entry(token).read()
        }
        fn frontend_needed_amount_of_collateral(self: @ContractState, token: ContractAddress, amount: u256, maximal_duration: u64, rate: u256) -> u256 {
            let price = self.price_information.entry(token).read();
            let ltv = self.ltv_information.entry(token).read();
            let max_interest = compute_interest(amount, rate, maximal_duration);
            inverse_value_of_asset(max_interest + amount, price, ltv)
        }
        
        fn frontend_get_user_points(self: @ContractState, user: ContractAddress) -> u256 {
            self.user_points.read(user)
        }
        fn frontend_get_total_points(self: @ContractState) -> u256 {
            self.total_points.read()
        }
    }
}