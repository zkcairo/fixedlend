// All constants used in the protocol

// Address
pub const ADMIN_ADDRESS: felt252 = 0x07d25449d864087e8e1ddbd237576c699dfe0ea98979d920fcf84dbd92a49e10;

// Category
pub const ETH_CATEGORY: felt252 = -1;
pub const USDC_CATEGORY: felt252 = -2;
pub const STRK_CATEGORY: felt252 = -3;

// Time
pub const SECONDS_PER_HOUR: u64 = 3600;
pub const SECONDS_PER_DAY: u64 = 86400;
pub const SECONDS_PER_YEAR: u64 = 31536000; // To simplify we assume we have only 365days, even if it's actually 365.25 in reality
pub const MIN_TIME_SPACING_FOR_OFFERS: u64 = SECONDS_PER_DAY;

// APY
// So right now, because of the scale used, you can express an apy like 0.01% which is 100
// Well one might want to change this scale, but we leave it like this because
// we may want one day to have APR_MIN_SPACING = 1 for instance
pub const APR_SCALE: u256 = 1000000;                             // Used in compute_interest
pub const APR_100_PERCENT: u256 = APR_SCALE;
pub const APR_1_PERCENT:   u256 = APR_100_PERCENT / 100;
pub const MIN_APR_SPACING_FOR_OFFERS: u256 = APR_1_PERCENT / 10; // Each offer need to has a rate modulo MIN_APR_SPACING_FOR_OFFERS == 0
// If we ever change the value of APR_PROTOCOL_FEE, it needs to be modulo MIN_APR_SPACING_FOR_OFFERS == 0 !!! (0% apr as fee is fine)
// Because, for a loan, the lender apr and the borrower apr is apr_protocol_fee,
// because both lender apr and borrower apr needs to be modulo MIN_APR_SPACING_FOR_OFFERS == 0, so as the difference
pub const APR_PROTOCOL_FEE: u256 = APR_1_PERCENT;
// If we ever change MIN_APR_SPACING_FOR_OFFERS, we need to be careful to either let the value value of MIN_APR,
// or do something because someone could have made a valid offer with a rate that is not valid anymore
// and therefore it becomes an offer impossible to take from now on
pub const MIN_APR: u256 = MIN_APR_SPACING_FOR_OFFERS;            // 0.1%
pub const MAX_APR: u256 = APR_1_PERCENT * 1000;                  // 1000%

// LTV
// Not the same scale as the APR but doesn't need the same precision anyway
// It should have been the same precision probably, mb
pub const LTV_SCALE: u256 = 10000;
pub const LTV_100_PERCENT: u256 = LTV_SCALE;
pub const LTV_50_PERCENT:  u256 = LTV_SCALE / 2;
pub const LTV_10_PERCENT:  u256 = LTV_SCALE / 10;
pub const LTV_1_PERCENT:   u256 = LTV_SCALE / 100;

// Constants
pub const VALUE_1e18: u256 = 1000000000000000000;