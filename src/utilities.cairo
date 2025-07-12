use fixedlend::datastructures::{Price, Match};
use starknet::{ContractAddress, get_caller_address};
use fixedlend::mock_erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
use fixedlend::constants;

// ASSERTS

pub fn assert_is_admin() {
    assert!(get_caller_address().into() == constants::ADMIN_ADDRESS , "Only admin can call this function");
}

// Ensure certain requirement on the price offer: the minimal spacing, correct apy, etc...
pub fn assert_validity_of_price(price: Price) {
    // APR check
    // Todo add test so that all price in between is available !! - same for time - todo
    assert!(price.rate % constants::MIN_APR_SPACING_FOR_OFFERS == 0, "APR must be modulo 0 of 0.1% apr (aka 5.1% is ok but 5.12% is not)");
    assert!(price.rate >= constants::MIN_APR, "Please lend/borrow at more than 0.1% APR");
    assert!(price.rate <= constants::MAX_APR, "Please lend/borrow at less than 1000% APR");
    // Time check
    assert!(price.minimal_duration <= price.maximal_duration, "The minimal duration should be less than the maximal duration for the combined match offer");
    let time_diff = price.maximal_duration - price.minimal_duration;
    assert!(time_diff >= constants::MIN_TIME_SPACING_FOR_OFFERS, "Please lend/borrow for at least a day in your offer");
}

// MATH

pub fn min2(a: u64, b: u64) -> u64 {
    if a <= b {
        return a;
    } else {
        return b;
    }
}

pub fn max2(a: u64, b: u64) -> u64 {
    if a >= b {
        return a;
    } else {
        return b;
    }
}

// base**exp
pub fn pow(base: u256, exp: u256) -> u256 {
    let mut result = 1;
    let mut i: u256 = 0;
    while i != exp {
        result *= base;
        i += 1;
    };
    return result;
}

// INTEREST

pub fn compute_interest(amount: u256, rate: u256, time_diff: u64) -> u256 {
    return amount * rate * time_diff.into() / (constants::SECONDS_PER_YEAR.into() * constants::APR_SCALE.into());
}

// Return (interest of the loan, fee paid to the platform)
pub fn interest_to_repay(match_offer: Match, current_time: u64) -> (u256, u256) {
    let time_diff = current_time - match_offer.date_taken;
    let amount = match_offer.amount;
    let lender_rate = match_offer.lending_rate;
    let interest_lender = compute_interest(amount, lender_rate, time_diff);
    let fee = compute_interest(amount, constants::APR_PROTOCOL_FEE, time_diff);
    return (interest_lender, fee);
}

// Return the maximal amount, interest and fee to repay for a given loan
pub fn max_to_repay(match_offer: Match) -> u256 {
    let max_loan_duration = match_offer.maximal_duration;
    let amount = match_offer.amount;
    let interest_and_fee = compute_interest(amount, match_offer.borrowing_rate, max_loan_duration);
    return amount + interest_and_fee;
}

// SCALE OF DECIMALS

pub fn to_18_decimals(address: ContractAddress, value: u256) -> u256 {
    let erc20 = IERC20Dispatcher { contract_address: address };
    let decimals: u256 = erc20.decimals().into();
    assert!(decimals <= 18, "Asset with stricly more than 18 decimals are not supported");
    value * pow(10, 18 - decimals)
}

pub fn to_assets_decimals(address: ContractAddress, value: u256) -> u256 {
    let erc20 = IERC20Dispatcher { contract_address: address };
    let decimals: u256 = erc20.decimals().into();
    assert!(decimals <= 18, "Asset with stricly more than 18 decimals are not supported");
    let powed = pow(10, 18 - decimals);
    assert!(value % powed == 0, "Value should be divisible by the asset decimals to avoid imprecision");
    value / powed
}

// VALUE OF COLLATERAL

// Todo: test_value_asset.cairo
// Not used in the protocol, only in frontend, so it's ok if it underflows
pub fn value_of_asset(amount: u256, price: u256, ltv: u256) -> u256 {
    amount * price * ltv / (constants::LTV_SCALE * constants::VALUE_1e18)
}

pub fn inverse_value_of_asset(amount: u256, price: u256, ltv: u256) -> u256 {
    // Round above to always have more collateral than needed
    1 + (amount * constants::LTV_SCALE * constants::VALUE_1e18) / (price * ltv)
}