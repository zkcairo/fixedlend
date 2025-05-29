use starknet::ContractAddress;

use starknet::{ contract_address_const, get_block_timestamp};
use fixedlend::mock_erc20::{ IERC20Dispatcher, IERC20DispatcherTrait };

use fixedlend::constants;
use fixedlend::{ IMyCodeDispatcher, IMyCodeDispatcherTrait };
use fixedlend::datastructures::{ LendingOffer, BorrowingOffer, Price };
use fixedlend::utilities::{ to_18_decimals, to_assets_decimals };
    
use snforge_std::{declare, ContractClassTrait, DeclareResultTrait };
// Cheatcodes
use snforge_std::{ CheatSpan, cheat_caller_address, start_cheat_block_timestamp_global };

fn deploy_contract(name: ByteArray) -> (IMyCodeDispatcher, ContractAddress) {
    let contract = declare(name).unwrap().contract_class();
    let (contract_address, _) = contract.deploy(@ArrayTrait::new()).unwrap();
    (IMyCodeDispatcher { contract_address }, contract_address)
}

// Deploy 2 erc20 contracts with each a different decimal value
fn deploy_erc20(decimals1: felt252, decimals2: felt252) -> Span<(IERC20Dispatcher, ContractAddress)> {
    let contract = declare("mock_erc20").unwrap().contract_class();
    let mut constructor_calldata_1 = array![decimals1];
    let (contract_address_1, _) = contract.deploy(@constructor_calldata_1).unwrap();
    let dispatcher_1 = IERC20Dispatcher { contract_address: contract_address_1 };
    let mut constructor_calldata_2 = array![decimals2];
    let (contract_address_2, _) = contract.deploy(@constructor_calldata_2).unwrap();
    let dispatcher_2 = IERC20Dispatcher { contract_address: contract_address_2 };
    array![(dispatcher_1, contract_address_1), (dispatcher_2, contract_address_2)].span()
}

// A basic price, that respect the condition of mycode::utilities::assert_validity_of_price
fn create_basic_price(rate: u256) -> Price {
    Price {
        rate: rate,
        minimal_duration: constants::SECONDS_PER_HOUR,
        maximal_duration: constants::SECONDS_PER_HOUR + constants::SECONDS_PER_DAY
    }
}

#[test]
fn test_increase_balance() {
    let user_lend = contract_address_const::<1111111111111>();
    let user_borrow = contract_address_const::<22222222222>();
    let user_admin = contract_address_const::<constants::ADMIN_ADDRESS>();

    // Deploy fixedlend
    let (contract, contract_address) = deploy_contract("MyCode");

    // Deploy 2 erc20 - 1 lend asset, 1 borrow asset
    let decimal_erc_lend = 18;
    let decimal_erc_borrow = 18;
    let arr = deploy_erc20(decimal_erc_lend, decimal_erc_borrow);
    let (erc20_lend, erc20_lend_address) = *arr[0];
    let (erc20_borrow, erc20_borrow_address) = *arr[1];
    let asset_category = -100;
    let price_lend = 1;
    let price_borrow = 1;
    let ltv_borrow = constants::LTV_100_PERCENT;
    let balance_user_lend = constants::VALUE_1e18;
    let protocol_balance_user_lend = to_18_decimals(erc20_lend_address, balance_user_lend);
    let balance_user_borrow = 2 * constants::VALUE_1e18;
    let protocol_balance_user_borrow = to_18_decimals(erc20_borrow_address, balance_user_borrow);

    // Mint the erc20s to the users
    erc20_lend.mint(user_lend, balance_user_lend);
    cheat_caller_address(erc20_lend_address, user_lend, CheatSpan::TargetCalls(1));
    erc20_lend.approve(contract_address, balance_user_lend);
    erc20_lend.mint(user_borrow, balance_user_lend);
    erc20_borrow.mint(user_borrow, balance_user_borrow);
    cheat_caller_address(erc20_lend_address, user_borrow, CheatSpan::TargetCalls(1));
    erc20_lend.approve(contract_address, balance_user_lend);
    cheat_caller_address(erc20_borrow_address, user_borrow, CheatSpan::TargetCalls(1));
    erc20_borrow.approve(contract_address, balance_user_borrow);
    assert!(erc20_lend.balanceOf(user_lend) == balance_user_lend, "Lender should have the correct balance of lend asset");
    assert!(erc20_lend.balanceOf(user_borrow) == balance_user_lend, "Borrower should have the correct balance of lend asset");
    assert!(erc20_borrow.balanceOf(user_borrow) == balance_user_borrow, "Borrower should have the correct balance of borrow asset");
    assert!(erc20_lend.balanceOf(contract_address) == 0, "Contract should not have any lend asset");
    assert!(erc20_borrow.balanceOf(contract_address) == 0, "Contract should not have any borrow asset");

    // Add the assets to the contract
    cheat_caller_address(contract_address, user_admin, CheatSpan::TargetCalls(2));
    contract.add_asset(erc20_lend_address, asset_category, true, price_lend, 0);
    contract.add_asset(erc20_borrow_address, asset_category, false, price_borrow, ltv_borrow);

    // Make lend offer
    let amount_match = protocol_balance_user_lend;
    let price_lend = create_basic_price(10 * constants::APR_1_PERCENT);
    cheat_caller_address(contract_address, user_lend, CheatSpan::TargetCalls(2));
    contract.deposit(erc20_lend_address, amount_match);
    contract.make_lend_offer(erc20_lend_address, amount_match, 0, price_lend);
    assert!(erc20_lend.balanceOf(user_lend) == protocol_balance_user_lend - amount_match, "Lender should have less lend asset after deposit");
    assert!(erc20_lend.balanceOf(contract_address) == balance_user_lend, "Contract should have the lend asset after deposit");

    // Make borrow offer
    let price_borrow = create_basic_price(11 * constants::APR_1_PERCENT);
    cheat_caller_address(contract_address, user_borrow, CheatSpan::TargetCalls(2));
    contract.deposit(erc20_borrow_address, protocol_balance_user_borrow);
    contract.make_borrow_offer(erc20_borrow_address, amount_match, price_borrow);
    assert!(erc20_borrow.balanceOf(user_borrow) == 0, "Borrower should have less borrow asset after deposit");
    assert!(erc20_borrow.balanceOf(contract_address) == balance_user_borrow, "Contract should have the borrow asset after deposit");

    // Match offer
    assert!(contract.balanceOf(user_lend, erc20_lend_address) == amount_match, "Lender should have the correct lend asset in the contract");
    assert!(contract.balanceOf(user_borrow, erc20_lend_address) == 0, "Borrower has 0 lend asset in the protocol before match");
    assert!(contract.balanceOf(user_borrow, erc20_borrow_address) == protocol_balance_user_borrow, "Borrower should have the correct borrow asset in the contract");
    contract.match_offer(0, 0, amount_match);
    assert!(contract.balanceOf(user_lend, erc20_lend_address) == 0, "Lender balance should be 0");
    assert!(contract.balanceOf(user_borrow, erc20_lend_address) == amount_match, "Borrower should have the asset of the lender after match");
    assert!(contract.balanceOf(user_borrow, erc20_borrow_address) < protocol_balance_user_borrow, "Balance of borrower didn't decreased after match");
    
    let current_time = get_block_timestamp();
    start_cheat_block_timestamp_global(current_time + constants::SECONDS_PER_DAY);

    // Repay offer
    cheat_caller_address(contract_address, user_borrow, CheatSpan::TargetCalls(1));
    contract.deposit(erc20_lend_address, amount_match);
    assert!(contract.balanceOf(user_borrow, erc20_lend_address) == 2*amount_match, "New deposit");
    cheat_caller_address(contract_address, user_borrow, CheatSpan::TargetCalls(1));
    contract.repay_offer(0);
    assert!(contract.balanceOf(user_borrow, erc20_lend_address) < amount_match, "Borrower should have less than what he borrowed+deposited");
    assert!(contract.balanceOf(user_borrow, erc20_borrow_address) == protocol_balance_user_borrow, "Borrower need to get his collateral in full");
}

