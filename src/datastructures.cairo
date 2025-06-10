use starknet::ContractAddress;

#[derive(Copy, Drop, starknet::Store, Serde, Debug, PartialEq)]
pub struct Price {
    pub rate: u256,            // See utilities.cairo for the computation of interest to pay
    pub minimal_duration: u64, // In secondes
    pub maximal_duration: u64
}

// Every u256 amounts of currency is scaled to 10**18 decimals
#[derive(Copy, Drop, starknet::Store, Serde, Debug, PartialEq)]
pub struct LendOffer {
    pub id: u64,
    pub is_active: bool,
    pub proposer: ContractAddress,
    pub token: ContractAddress,
    pub total_amount: u256,
    pub amount_available: u256,
    pub price: Price,
    pub accepted_collateral: u256, // Not used yet
}

// Every u256 amounts of currency is scaled to 10**18 decimals
#[derive(Copy, Drop, starknet::Store, Serde, Debug, PartialEq)]
pub struct BorrowOffer {
    pub id: u64,
    pub is_active: bool,
    pub proposer: ContractAddress,
    pub total_amount: u256, 
    pub amount_available: u256,
    pub price: Price,
    pub token_collateral: ContractAddress,
}

#[derive(Copy, Drop, starknet::Store, Serde, Debug, PartialEq)]
pub struct Match {
    pub id: u64,
    pub is_active: bool,
    pub lend_offer_id: u64,
    pub borrow_offer_id: u64,
    pub amount: u256,               // How much we borrowed
    pub amount_collateral: u256,    // How much collateral there is in exchange
    pub lending_rate: u256,
    pub date_taken: u64,
    pub borrowing_rate: u256,
    pub minimal_duration: u64,
    pub maximal_duration: u64,
}