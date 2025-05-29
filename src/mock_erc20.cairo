// The interface is used for the smart contract
// The implementation is only used for the tests
// Todo deplacer dans le dossier test

use starknet::ContractAddress;

#[starknet::interface]
pub trait IERC20<TContractState> {
    fn decimals(self: @TContractState) -> felt252;
    fn transfer(ref self: TContractState, recipient: ContractAddress, amount: u256);
    fn balanceOf(self: @TContractState, account: ContractAddress) -> u256;
    fn approve(ref self: TContractState, spender: ContractAddress, amount: u256);
    fn transferFrom(ref self: TContractState, sender: ContractAddress, recipient: ContractAddress, amount: u256);
    fn allowance(self: @TContractState, owner: ContractAddress, spender: ContractAddress) -> u256;
    fn mint(ref self: TContractState, account: ContractAddress, amount: u256); // No restriction on who can mint
}

#[starknet::contract]
pub mod mock_erc20 {
    use starknet::storage::{ StoragePointerReadAccess, StoragePointerWriteAccess };
    use starknet::{ContractAddress, get_caller_address};
    use starknet::storage::{Map, StoragePathEntry};

    #[storage]
    struct Storage {
        decimals: felt252,
        total_supply: u256,
        balances: Map<ContractAddress, u256>,
        allowances: Map<(ContractAddress, ContractAddress), u256>,
    }

    #[constructor]
    fn constructor(ref self: ContractState, decimals: felt252) {
        self.decimals.write(decimals);
    }

    #[abi(embed_v0)]
    impl IERC20Impl of super::IERC20<ContractState> {
        fn decimals(self: @ContractState) -> felt252 {
            self.decimals.read()
        }
        
        fn transfer(ref self: ContractState, recipient: ContractAddress, amount: u256) {
            let caller = get_caller_address();
            let caller_balance = self.balances.entry(caller).read();
            let recipient_balance = self.balances.entry(recipient).read();
            self.balances.entry(caller).write(caller_balance - amount);
            self.balances.entry(recipient).write(recipient_balance + amount);
        }
        
        fn balanceOf(self: @ContractState, account: ContractAddress) -> u256 {
            self.balances.entry(account).read()
        }

        fn approve(ref self: ContractState, spender: ContractAddress, amount: u256) {
            let caller = get_caller_address();
            self.allowances.entry((caller, spender)).write(amount);
        }

        fn transferFrom(ref self: ContractState, sender: ContractAddress, recipient: ContractAddress, amount: u256) {
            let caller = get_caller_address();
            let allowance = self.allowances.entry((sender, caller)).read();
            assert!(allowance >= amount, "MockERC20: Insufficient allowance");
            let sender_balance = self.balances.entry(sender).read();
            let recipient_balance = self.balances.entry(recipient).read();
            self.balances.entry(sender).write(sender_balance - amount);
            self.balances.entry(recipient).write(recipient_balance + amount);
            self.allowances.entry((sender, caller)).write(allowance - amount);
        }

        fn allowance(self: @ContractState, owner: ContractAddress, spender: ContractAddress) -> u256 {
            self.allowances.entry((owner, spender)).read()
        }

        fn mint(ref self: ContractState, account: ContractAddress, amount: u256) {
            let total_supply = self.total_supply.read();
            let account_balance = self.balances.entry(account).read();
            self.total_supply.write(total_supply + amount);
            self.balances.entry(account).write(account_balance + amount);
        }
    }
}

