// All constants used in the protocol

// Address
pub const ADMIN_ADDRESS: felt252 = 0x07d25449d864087e8e1ddbd237576c699dfe0ea98979d920fcf84dbd92a49e10;

pub const ETH_ADDRESS: felt252 = 0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7;

pub const USDT_ADDRESS: felt252 = 0x068f5c6a61780768455de69077e07e89787839bf8166decfbf92b645209c0fb8;
pub const USDC_ADDRESS: felt252 = 0x053c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8;
pub const DAI_ADDRESS: felt252 = 0x05574eb6b8789a91466f902c380d978e472db68170ff82a5b650b95a58ddf4ad;
pub const DAIV0_ADDRESS: felt252 = 0x00da114221cb83fa859dbdb4c44beeaa0bb37c7537ad5ae66fe5e0efd20e6eb3;

pub const STRK_ADDRESS: felt252 = 0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d;

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
pub const APR_1_PERCENT: u256 = 10000;
pub const APR_01_PERCENT: u256  = APR_1_PERCENT / 10;
pub const APR_PROTOCOL_FEE: u256 = APR_1_PERCENT;
pub const APR_SCALE: u256     = APR_1_PERCENT * 100; // Used in compute_interest
pub const MIN_APR: u256 = APR_01_PERCENT;            // 0.1%
pub const MAX_APR: u256 = APR_1_PERCENT * 1000;      // 1000%

// LTV
pub const LTV_SCALE: u256 = 10000;
pub const LTV_100_PERCENT: u256 = LTV_SCALE;
pub const LTV_50_PERCENT: u256 = LTV_SCALE / 2;
pub const LTV_10_PERCENT: u256 = LTV_SCALE / 10;
pub const LTV_1_PERCENT: u256  = LTV_SCALE / 100;

// Constants
pub const VALUE_1e18: u256 = 1000000000000000000;