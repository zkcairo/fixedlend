# README

FixedLend, a P2P lending app on Starknet for yield trading/hedging.

Right now, only ETH to be lent and fETH (an asset of Starknet which is like wstETH, accrues in value against ETH) as collateral assets are supported.

## Description of the storage, data structures, etc...

### Data structures used

All the data structures used are defined in `datastructure.cairo`.

```rust
#[derive(Copy, Drop, starknet::Store, Serde, Debug, PartialEq)]
pub struct Price {
    pub rate: u256,            // See utilities.cairo for the computation of interest to pay
    pub minimal_duration: u64, // In seconds
    pub maximal_duration: u64
}
```
Pretty self-explanatory.

`rate` is the APR; it's a fixed-point number on a scale defined in `constants.cairo`,
1% APR is `pub const APR_1_PERCENT: u256 = 10000;`.
The interest to pay is calculated in `utilities.cairo`.
(We use APR instead of APY for the simplicity of computation, because computing what is 1% APY for a 36.5-day loan is annoying, but 1% APR for a 36.5-day loan is 0.1% of the APR for 365 days; it's linear.)
(We also assume the year only has 365 days instead of 365.25 days. Well, simplicity again.)

`minimal_duration` and `maximal_duration` are the minimal duration of a loan and the maximal duration of it.
It is a time in seconds.
To check the time, we always use the block time with `get_block_timestamp()`.
Yes, miners can slightly cheat, but it's okay.
The repayment of a loan can only take place in the following date interval:
`[date_taken_of_a_loan + minimal_duration, date_taken_of_a_loan + maximal_duration]`.
The liquidation of a loan can only take place in the following date interval:
`[date_taken_of_a_loan + maximal_duration, +inf)`.
So at the exact date `date_taken_of_a_loan + maximal_duration`, both a liquidation and a repayment can happen. It's okay, we allow this.
When a loan is made, there is always `maximal_duration > minimal_duration + MIN_TIME_SPACING_FOR_OFFERS`, and this "min time spacing" value is set to be a day, so there is at least a full day for the borrower to repay. If the chain freezes for a day or so, well, too bad for the borrower. It's okay and acknowledged.

```rust
// Every u256 amounts of currency is scaled to 10^18 decimals
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
```

Created when a user makes a lend offer with `make_lend_offer`.

`id` is a unique ID. Used when we match offers and repay/liquidate; users/frontends are supposed to provide the ID they are interested in to the smart contract.

When `is_active` is false, it's as if the offer doesn't exist; it cannot be lent to/borrowed from, a match cannot be repaid/liquidated, etc...
Essentially, once a match is repaid/liquidated, we set its `is_active` to false to mark that it won't ever be used again.

`proposer` is the smart contract that made this offer. We say smart contract because on Starknet there is no Externally Owned Account, only smart contract addresses/wallets. We don't do any restriction on the proposer; we allow the 0 address, etc...
The proposer is the one who calls the smart contract with `make_lend_offer`, so it cannot be the 0 address anyway.

`token` is what we lend. Needs to be whitelisted by the admin beforehand.

`amount_available` is what can be borrowed from this offer. It can be a too-large value, e.g., 10 ETH, even if the user only has 1 ETH in the protocol right now. In this case, `amount_available` is still 10 ETH, but what can be borrowed is only 1 ETH.

`total_amount` is the total amount of an offer. Initially at creation, it is `amount_available`, but once someone has borrowed from this offer, `amount_available` then decreases, but `total_amount` does not decrease. This parameter isn't used anywhere in the smart contract; it's somewhat informative for the frontend so the user can see how much is borrowed from their offer. It's a pretty useless parameter for the smart contract, merely a frontend utility which could be removed, to be honest, but storage is cheap, so.

`price` is the APR at which we lend.

`accepted_collateral` is not used yet.

```rust
// Every u256 amounts of currency is scaled to 10^18 decimals
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
```

Created when a user makes a borrow offer with `make_borrow_offer`.

Parameters `id`, `is_active`, `proposer`, `total_amount`, and `price` are the same as above.

`token_collateral` is the token we use as collateral.

```rust
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
```

Created when a loan is made with `match_offer`.

Parameters `id` and `is_active` are the same as above.

`lend_offer_id` and `borrow_offer_id` are the unique IDs of the lend offer and the borrow offer which are used for this loan.

`amount` is how much is lent.

`amount_collateral` is how much collateral there is in exchange. Could be recomputed on the fly when we need it, but storage is cheap and it's simpler this way.

`lending_rate` and `borrowing_rate` are the two rates: the APR the lender earns, and the APR the borrower pays. The difference is the platform fee. Right now, the platform fee is exactly 1%, so there is no need for these two variables; only one is sufficient. But in the future, this might change, hence the two variables.

`date_taken` is the block timestamp at which the loan is taken.

`minimal_duration` and `maximal_duration` are the minimal and maximal duration of the loan. These parameters were also in the two above structures in the `price` field, which includes these parameters. Here, because we have two rates, we don't have this `price` field, hence the fact these two minimal and maximal durations appear directly in the data structure.

### Storage

```rust
// Information about users
assets_user: Map<ContractAddress, Map<ContractAddress, u256>>, // User => (Asset => quantity)
lend_offers: Vec<LendOffer>,
borrow_offers: Vec<BorrowOffer>,
current_matches: Vec<Match>,
```

`assets_user` describes how many assets each user has in the protocol which aren't used right now in a loan. They can withdraw these assets.
Both functions `deposit` and `withdraw` increase/decrease this value.

All three vectors `lend_offers`, `borrow_offers`, and `current_matches` are all the lend/borrow offers and the loans of the protocol. Many of them can be with the parameter `is_active` being false, which means it's as if they don't exist.

```rust
// Information about assets
category_information: Map<ContractAddress, felt252>, // Which asset is of which category
assets_lender: Map<ContractAddress, bool>,           // Assets accepted to be lent
assets_borrower: Map<ContractAddress, bool>,         // Assets accepted to borrow with
price_information: Map<ContractAddress, u256>,       // Price of assets - used in utilities.cairo/inverse_value_of_asset
ltv_information: Map<ContractAddress, u256>,         // Loan To Value info about assets - used too in inverse_value_of_asset
```

All the information about assets. Only the admin address can modify this information.

`category_information` describes which asset is in which category. Assets are grouped by category if they are "correlated", so for instance, both ETH and fETH have the same category. If wstETH were to be added to the protocol, its category would be the one of ETH.

`assets_lender` is true if an asset is used to be lent, false otherwise.
For instance, ETH will have value true in this map, but fETH will have false.

`assets_borrower` is true if an asset is to be used as a collateral, false otherwise.
For instance, fETH will have value true in this map, but ETH will have false.

`price_information` is how much 10^18 of a borrowable asset is worth in the corresponding lendable asset.
So for instance, the fETH price field is 10^18, because we consider that 1 fETH = 1 ETH, so 10^18 fETH = 10^18 ETH, as both ERC-20s of ETH and fETH have the same decimals parameter.
If wstETH were to be added to the protocol, as 1 wstETH = 1.3 ETH (or something like that), then its price value would be 1.3 * 10^18.

`ltv_information` is the LTV of a borrowable asset. The scale is from 0 to `LTV_100_PERCENT` defined in `constants.cairo`, which corresponds to 100%.

```rust
// Points
points_multiplier: u256,
total_points: u256,
user_points: Map<ContractAddress, u256>,
points_multiplier_per_asset: Map<ContractAddress, u256>,
```

Used to keep track of the "points" of the protocol for a future airdrop. Yes, it's supposed to be off-chain, but storage is cheap.

### Public functions of the contract

```rust
// Deposit/Withdraw
fn deposit(ref self: TContractState, token: ContractAddress, amount: u256);
fn withdraw(ref self: TContractState, token: ContractAddress, amount: u256);
```

Before using the app, users need to deposit money in the app.
This is done with the function `deposit`. They can withdraw with
the function `withdraw`.

`token` is the asset.

`amount` is the amount they deposit scaled to 10^18 decimals. So for an ERC-20 with 18 decimals, if you deposit an amount `y`, then `y` amount of currency is taken from your ERC-20. If the asset has only 10^6 decimals, then if you deposit an amount `y`, then `y/10^(18-6)` is taken from your ERC-20.
This computation is done with the function `to_assets_decimals` of `utilities.cairo`.
Both withdraw and deposit use this function, so if you deposit `y` then withdraw `y`, your final ERC-20 balance is the same as the starting ERC-20 balance.

```rust
// Make/Disable offers
fn make_lend_offer(ref self: TContractState, token: ContractAddress, amount: u256, accepted_collateral: u256, price: Price);
fn disable_lend_offer(ref self: TContractState, id_offer: u64);
fn make_borrow_offer(ref self: TContractState, token: ContractAddress, amount: u256, price: Price);
fn disable_borrow_offer(ref self: TContractState, id_offer: u64);
```

`make_lend_offer` creates a lend offer on the marketplace. It can be disabled at any time by whoever created it with `disable_lend_offer`. The `amount` parameter is scaled to 10^18, not in the scale of the token. The parameter `accepted_collateral` is used to create the struct `LendOffer` but is not used anywhere.
Same for the borrow offers.

```rust
// Match, Repay, and Liquidate offers
fn match_offer(ref self: TContractState, lend_offer_id: u64, borrow_offer_id: u64, amount: u256);
fn repay_offer(ref self: TContractState, offer_id: u64);
fn liquidate_offer(ref self: TContractState, offer_id: u64);
```

Any compatible offers can create a loan thanks to `match_offer`. This loan can either be repaid with `repay_offer` or liquidated with `liquidate_offer`. In case of liquidation, it's as if it's a repayment if the borrower has enough money in the protocol; otherwise, their collateral is taken.

## How users are expected to use the app:

### Flow of use:

1. Borrowers deposit non-yielding assets (e.g., ETH) with `deposit`.
2. Lenders deposit yielding assets (e.g., fETH, wstETH, etc.) with `deposit`.
3. Both borrowers and lenders make offers on the market with `make_lend_offer` and `make_borrow_offer`.
4. Anyone can match any compatible offers - usually someone that wants to take an offer will make a corresponding offer and immediately match it with their wanted offer. This is done with `match_offer`.
5. Offers are repaid with `repay_offer` or `liquidate_offer`.

### The different repayment/liquidation flows:

1. A regularly repaid loan:
Only the borrower can repay, and then it just takes the money that the borrower has in the protocol to transfer it to the lender.
The borrower has to repay within the allowed time.
In this case, the lender gets what they lent, and some interest.

2. A liquidation where the borrower still has the money to repay the lender:
In this case, when the liquidate function is called, the lender is repaid with the amount
that the borrower has in the protocol.
So if the loan was 100 ETH with 200 fETH collateral, and the borrower has 110 ETH in the protocol,
then the liquidation does use the 110 ETH to repay the lender, and the collateral is not touched.
In this case, the lender gets what they lent, and some interest.

3. A liquidation but the borrower doesn't have the money to repay the lender:
Their collateral is transferred to the lender. The value of this collateral isn't recomputed, so the lender can end up with a loss.
The LTV ensures this won't be the case, hopefully, but it can happen when yield-bearing assets de-peg.
So if the loan was 100 ETH with 200 fETH collateral, and the borrower has 0 ETH in the protocol,
all the 200 fETH is transferred to the lender. If for instance the borrower has 1000 fETH in the protocol,
only 200 fETH is transferred to the lender, and the rest is not touched.
In this case, the lender does not get what they lent, but gets some collateral instead.

## When do lenders/borrowers lose money:

Users can lose money if the smart contract is hacked.
In this case, all the funds deposited may be lost.
Otherwise, here are the cases where users can lose money:

### Lender

A lender can lose money when a collateral massively de-pegs.

For instance, if a lender lends 1 ETH against 2 fETH, and the value of fETH drops to 0,
then the borrower will likely not repay the loan. The lender can liquidate it to
get the 2 fETH, which will be worth 0.
Else, if the collateral doesn't de-peg, the lender does not lose money upon liquidation in any circumstances.
If there is some liquidation, the lender will get, in this example, 2 fETH instead of their 1 ETH + interest,
which is worth more than the 1 ETH + interest.

If a collateral slightly de-pegs, e.g., 1 fETH was supposed to be worth 1 ETH but is now worth only 0.8 ETH,
then the lender still doesn't lose money thanks to the LTV parameter. Right now, it is set to 50%,
so 2 fETH are required to lend 1 ETH, and therefore upon liquidation, the lender will get 2 fETH worth 1.6 ETH,
which is larger than their deposit of 1 ETH.

### Borrower

A borrower cannot lose money when they repay a loan.
If they get liquidated and the collateral has not de-pegged, then they lose money (which is earned by the lender as described above).

## Information for auditors

### Audit scope:

In scope:
+ `lib.cairo`: lines 1-424 (424 LOC)
+ `utilities.cairo`: whole file (102 LOC)
+ `datastructure.cairo`: whole file (48 LOC)
+ `constants.cairo`: whole file (41 LOC)

Not in scope:
+ `lib.cairo`: lines 425-591 - this is not used in the contract, only reader functions used in the frontend
+ `mock_erc20.cairo`: whole file - not used in the contract, only in the tests
+ all the tests: because these are tests

## Assumptions

We assume the ERC-20s we use aren't malicious. We whitelist each of them. A non-whitelisted ERC-20 contract cannot be used in the smart contract, so we make the assumption that they are not malicious and cannot re-enter the smart contract.

We assume the ERC-20s have decimals less than or equal to 18.
We also assume this decimal value doesn't change.
It is the responsibility of the admin address to not whitelist malicious ERC-20s that do not respect this condition.

## "Invariants"

Unfortunately, there are limited tools to verify invariants on Starknet, so this section is purely descriptive
and is not verified by any tool whatsoever.

### The important invariants

The field `assets_user` describes how much each user has deposited of what. The following invariants are important because if broken, then money can be lost. Other invariants about other attributes are less important.

Only ERC-20s with decimals less than or equal to 18 can be used in this protocol. Assets that can be used in the protocol are whitelisted by the admin address, which we assume will not list any ERC-20 with more than 18 decimals. We also assume that the `decimals` function of an ERC-20 will always return the same value. Because assets are whitelisted by the admin address, this is an assumption of the protocol which we assume is true. The following invariants and the correctness of the protocol make these assumptions.

If a user deposits an amount `y` of an ERC-20 with decimals `n`, then **EXACTLY** `y/10^(18-n)` amount of this ERC-20 is taken from their account. No loss of precision can occur, as the function responsible for this computation, `to_assets_decimals` in `utilities.cairo`, has this requirement in its code.

If a user deposits an amount `y` of an ERC-20, then
does some loans, waits some time, other people do some actions, etc... then once all of their loans are repaid, if no liquidation can occur, the user can withdraw at least `y` amount of the ERC-20 they deposited.

At any time, the storage field `assets_user` corresponds to the amount of money deposited into the protocol by a user which they can withdraw at any time. No matter the value (unless it is such a high number it causes an overflow), the user can withdraw all of it thanks to the function `withdraw`; this function will not fail or work incorrectly.
These absurdly high values that cause an overflow will not be reached for the assets currently supported by the protocol, which are ETH and fETH.

At any time, the "missing" values of the storage field `assets_user` correspond to the sum of all current loans. So for instance, if the user deposits `x`, makes two loans of amount `y` and `z`, then `assets_user` will have the value `x-y-z`.

The `asset_user` field is invariant when no "deposit/withdraw" are made.
So the invariant is somewhat as follows: each time a value for a lending asset gets subtracted from `assets_user`, unless a liquidation occurs, then this value will be added back to `assets_user`. And each time a value for a borrowable asset gets subtracted from `assets_user`, then this value will be added back to `assets_user` either to the lender (in case of a liquidation) or to the borrower when they repay the loan.

Once an object has a field `is_active` set to false, it can never be reset to true. It's expected, if a user wants to re-activate an offer, they just create a new one.
Similarly, a loan can only be repaid or liquidated once.

If a user makes an offer on the marketplace with maximal duration `t`, then no loans of more than `t` seconds can take place. Once this user has delisted all of their offers and waited for `t` seconds, the user can then always withdraw all of their money in the protocol.
Similarly, if a user makes an offer on the marketplace with minimal duration `t`, then no loans of less than `t` seconds can take place.

All admin functions can only be called by the admin address.

Each ID of each structure is unique. A `LendOffer` object can have the same ID as a `BorrowOffer` object, but no two distinct `LendOffer` objects can have the same ID.

When no liquidation occurs, the lender receives more than what they lent.

When no liquidation occurs, the borrower receives back exactly their collateral.

For a given loan, the collateral is more in value (according to the protocol, not market value, i.e., if a de-peg happens then it's not true) than all the amount borrowed plus the maximal interest and fee that will be paid. So a loan of 1 year requires more collateral than a loan of 1 day of the same APR.

No one can make a lend/borrow offer on behalf of a user.
No one can disable a lend/borrow offer on behalf of the user who made it (the `proposer`).
If two offers are "compatible" (i.e., a loan can happen), however, anyone can make this loan happen.

At any time, the user can always disable any of their lend/borrow offers.

### Other invariants

The protocol is permissioned for the assets it allows, both in what can be lent and what can be used as collateral. So if an asset does not have a value in the storage `category_information` set, then it cannot be used neither as a lending asset nor as collateral. Only the admin address can whitelist tokens.

All the lend offers and borrow offers available to take are exactly all the elements of `lend_offers` and `borrow_offers` of the storage with the field `is_active` set to true.
All the current loans of the protocol are exactly all the elements of `current_matches` of the storage with the field `is_active` set to true.

Only the admin address can modify the information of the following fields of the storage:
`category_information`,
`assets_lender`,
`assets_borrower`,
`price_information`, and
`ltv_information`.

The sum of all the elements `user_points` of the storage is the value
`total_points` of the storage.

When a loan is made, there is always `maximal_duration > minimal_duration + SECONDS_PER_DAY`. There is at least a full day for the borrower to repay.
This is verified in the function `match_offer` with the call `assert_validity_of_price(price_match);`.

## How to run build/tests:

Build: `scarb build`

Run the tests: `snforge test`

# Risks of using the app:

## General risks

The code is not audited. It could have bugs that could result in a total loss of funds.

Starknet and Cairo are experimental technology. They could have bugs that could result in a total loss of funds.

I reserve the right to modify your number of points at any time.
Maybe there won't be an airdrop.
Points do not entitle you to a potential airdrop.
I reserve the right to ban you from the points program at any time.

I am not liable for any loss of funds you may incur when using my app.
By interacting with the app, you confirm that you won't sue me for loss of funds or anything else related to my app.

## Disclaimer of Warranty

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

## Limitation of Liability

In no event shall the authors or copyright holders be liable for any special, incidental, indirect, or consequential damages whatsoever (including, without limitation, damages for loss of business profits, business interruption, loss of business information, or any other pecuniary loss) arising out of the use of or inability to use this software, even if the authors or copyright holders have been advised of the possibility of such damages.