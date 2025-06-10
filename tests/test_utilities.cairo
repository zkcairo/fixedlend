use starknet::ContractAddress;

use starknet::{ contract_address_const, get_block_timestamp};
use fixedlend::mock_erc20::{ IERC20Dispatcher, IERC20DispatcherTrait };

use fixedlend::constants;
use fixedlend::{ IMyCodeDispatcher, IMyCodeDispatcherTrait };
use fixedlend::datastructures::{ LendOffer, BorrowOffer, Price };
use fixedlend::utilities::{ to_18_decimals, to_assets_decimals, value_of_asset, inverse_value_of_asset, interest_to_repay };
use fixedlend::datastructures::{ Match };

// A basic price, that respect the condition of mycode::utilities::assert_validity_of_price
fn create_basic_price(rate: u256) -> Price {
    Price {
        rate: rate,
        minimal_duration: constants::SECONDS_PER_HOUR,
        maximal_duration: constants::SECONDS_PER_HOUR + constants::SECONDS_PER_DAY
    }
}

// ASSERTS
// None

// MATH
// Todo

// INTEREST
#[test]
#[fuzzer]
fn test_amount_after_a_year(_apy: u256) {
    let start_time = 0;
    let end_time = start_time + constants::SECONDS_PER_YEAR;
    let apy = constants::MIN_APR + (_apy % constants::MAX_APR);
    let rate = apy * constants::APR_1_PERCENT;
    let amount = 10000000;
    let current_match = Match {
        id: 1,
        is_active: true,
        lend_offer_id: 1,
        borrow_offer_id: 1,
        amount: amount.into(),
        amount_collateral: 0.into(), // Not used in this test
        lending_rate: rate,
        date_taken: start_time,
        borrowing_rate: rate, // Same as lending rate for simplicity
        minimal_duration: constants::SECONDS_PER_HOUR,
        maximal_duration: constants::SECONDS_PER_HOUR + constants::SECONDS_PER_DAY
    };

    let (interest, fee) = interest_to_repay(current_match, end_time);
    let excepted_interest = amount * apy / 100;
    let excepted_fee = amount * 1 / 100;

    assert!(interest == excepted_interest);
    assert!(fee == excepted_fee);
}

#[test]
#[fuzzer]
fn test_amount_after_a_day(_apy: u256) {
    let start_time = 0;
    let end_time = start_time + constants::SECONDS_PER_DAY;
    let apy = constants::MIN_APR + (_apy % constants::MAX_APR);
    let rate = apy * constants::APR_1_PERCENT;
    let amount = 10000000;
    let current_match = Match {
        id: 1,
        is_active: true,
        lend_offer_id: 1,
        borrow_offer_id: 1,
        amount: amount.into(),
        amount_collateral: 0.into(), // Not used in this test
        lending_rate: rate,
        date_taken: start_time,
        borrowing_rate: rate, // Same as lending rate for simplicity
        minimal_duration: constants::SECONDS_PER_HOUR,
        maximal_duration: constants::SECONDS_PER_HOUR + constants::SECONDS_PER_DAY
    };

    let (interest, fee) = interest_to_repay(current_match, end_time);
    let excepted_interest = amount * apy / 100 / 365; // Number of day in a year - unprecise yes, as in mycode::constants.cairo
    let excepted_fee = amount * 1 / 100 / 365;

    assert!(interest == excepted_interest);
    assert!(fee == excepted_fee);
}

#[test]
fn test_edge_case_zero_duration() {
    let start_time = 1000;
    let end_time = start_time; // Zero duration
    let amount = 10000000;
    let apy = constants::MIN_APR;
    let rate = apy * constants::APR_1_PERCENT;
    let current_match = Match {
        id: 1,
        is_active: true,
        lend_offer_id: 1,
        borrow_offer_id: 1,
        amount: amount.into(),
        amount_collateral: 0.into(), // Not used in this test
        lending_rate: rate,
        date_taken: start_time,
        borrowing_rate: rate, // Same as lending rate for simplicity
        minimal_duration: constants::SECONDS_PER_HOUR,
        maximal_duration: constants::SECONDS_PER_HOUR + constants::SECONDS_PER_DAY
    };

    let (interest, fee) = interest_to_repay(current_match, end_time);

    assert!(interest == 0);
    assert!(fee == 0);
}

// SCALE OF DECIMALS
// Todo

// VALUE OF COLLATERAL

#[test]
#[fuzzer]
fn check_value_of_collateral(price: u256, ltv: u256, amount_: u128) {
    let price_borrow = price % (10000 * constants::VALUE_1e18);
    let ltv_borrow = ltv % constants::LTV_100_PERCENT;
    let amount = amount_.into(); // To avoid overflows

    let inverse_value = inverse_value_of_asset(amount, price_borrow, ltv_borrow);
    let value = value_of_asset(inverse_value, price_borrow, ltv_borrow);
    
    // println!(" => amount: {}, price_borrow: {}, ltv_borrow: {}", amount, price_borrow, ltv_borrow);
    // println!(" => inverse_value: {}", inverse_value);
    // println!(" => value: {}", value);

    assert!(value >= amount);
}

