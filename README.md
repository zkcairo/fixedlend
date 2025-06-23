# README

FixedLend, a p2p lending app on starknet for yield trading/hedging.

Right now, only eth to be lent and feth (an asset of starknet which is like wsteth, accrues in value against eth) as collateral assets are supported.

## Description of the storage, datastructures, etc...

### Datastructures used

All the datastructures used are defined in `datastructure.cairo`.

```rust
#[derive(Copy, Drop, starknet::Store, Serde, Debug, PartialEq)]
pub struct Price {
    pub rate: u256,            // See utilities.cairo for the computation of interest to pay
    pub minimal_duration: u64, // In secondes
    pub maximal_duration: u64
}
```
Pretty self explanatory.

`rate` is the apr it's a fixed point number on a scale defined in `constants.cairo`,
1% apr is `pub const APR_1_PERCENT: u256 = 10000;`.
The interest to pay is done in `utilities.cairo`.
(We use APR instead of APY for the simplicity of computation, because computing what is 1% APY for a 36.5days loan is anoying but 1% APR of a 36.5days is 0.1% APR for 365days it's linear.)
(We also assume the year only has 365days instead of 365.25days well simplicity again)

`minimal_duration` and `maximal_duration` are the minimal duration of a loan and the maximal duration of it.
It is a time in second.
To check the time, we always use the blocktime with `get_block_timestamp()`.
Yes miners can slightly cheat but it's ok.
The repayment of a loan can only take place in the following date interval
`[date_taken_of_a_loan + minimal_duration, date_taken_of_a_loan + maximal_duration]`.
The liquidation of a loan can only take place in the following date interval
`[date_taken_of_a_loan + maximal_duration; +inf[`.
So at date exactly `date_taken_of_a_loan + maximal_duration` both a liquidation and a repayment can happen, it's ok we allow this.
When a loan is made, there is always `maximal_duration > minimal_duration + MIN_TIME_SPACING_FOR_OFFERS`, and this "min time spacing" value is set to be a day, there is at least a full day for the borrower to repay. If the chain freeze for a day or so well too bad for the borrower, it's ok and acknowledged.

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

Created when a user make a borrow offer with `make_lend_offer`.

`id` is a unique id. Used when we match offer and repay/liquidate, users/frontends are supposed to provide the id they are interested in to the smart contract.

When `is_active` is false, it's as if the offer doesn't exist, it cannot be lend/borrow to, a match cannot be repay/liquidate, etc...
Essentialy, once a match is repaid/liquidated well we set its `is_active` to false to mark that it won't ever be used again.

`proposer` is the smart contract that made this offer, we say smart contract because on starknet there is no external owned address only smart contract address/wallet. We don't do any restriction on the proposer, we allow the 0 address, etc...
The proposer is the one who calls the smart contract with `make_lend_offer` so it cannot be the 0 address anyway.

`token` is what we lend. Need to be whitelisted by the admin beforehand.

`available_amount` is what can be borrowed from this offer. It can be a too large value, eg 10eth, even if the user only has right now 1eth in the protocol. In this case, available amount is still 10eth but what can be borrowed is only 1eth.

`total_amount` is the total amount of an offer. Initially at creation it is available amount, but once someone borrowed from this offer available then decreases but total amount doesn't decreases. This parameter isn't used anywhere in the smart contract, it's somewhat informative for the frontend so the user can see how much is borrowed from its offer. It's a pretty useless parameter for the smart contract merely a frontend utilities which could be removed tbh but storage is cheap so.

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

Created when a user make a borrow offer with `make_borrow_offer`.

Parameters `id`, `is_active`, `proposed`, `total_amount`, and `price` are the same as above.

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

Create when a loan is made with `match_offer`.

Parameters `id`, and `is_active` are the same as above.

`lend_offer_id`, and `borrow_offer_id` are the unique ids of the lend offer and the borrow which are used for this loan.

`amount` is how much is lent.

`amount_collateral` is how much collateral there is in exchange. Could be recomputed on the fly when we need it but storage cheap and it's simplier this way.

`lending_rate` and `borrowing_rate` are the two rates, the APR the lender earns, and the APR the borrower pays. The difference is the platform fee. Right now, the platform fee is exactly 1%, so there is no need for these two variables only one is sufficient but in the future this might change hence the two variables.

`date_taken` is the block timestamp at which the loan is taken.

`minimal_duration` and `maximal_duration` are the minimal and maximal duration of the loan. These parameters were also in the two above structure in the field `price` which includes these parameters. Here because we have two rates, we don't have this field `price` hence the fact these two minimal durations appears directly in the datastructure.

### Storage

```rust
// Informations about users
assets_user: Map<ContractAddress, Map<ContractAddress, u256>>, // User => (Asset => quantity)
lend_offers: Vec<LendOffer>,
borrow_offers: Vec<BorrowOffer>,
current_matches: Vec<Match>,
```

`assets_user` describes how many of assets each user has in the protocol which aren't used right now in a loan. They can withdraw these assets.
Both functions `deposit` and `withdraw` increases/decreases this value.

All three vectors `lend_offers`, `borrow_offers`, and `current_matches` are all the lend/borrow offers and the loans of the protocol, many of them can be with the parameter `is_active` being false which means it's as if they don't exist.

```rust
// Informations about assets
category_information: Map<ContractAddress, felt252>, // Which asset is of which category
assets_lender: Map<ContractAddress, bool>,           // Assets accepted to be lent
assets_borrower: Map<ContractAddress, bool>,         // Assets accepted to borrow with
price_information: Map<ContractAddress, u256>,       // Price of assets - used in utilities.cairo/inverse_value_of_asset
ltv_information: Map<ContractAddress, u256>,         // Loan To Value info about assets - used too in inverse_value_of_asset
```

All the informations about assets. Only the admin address can modify these informations.

`category_information` describes which asset is in which category. Assets are grouped by category if they are "corrolated", so for instance both eth and feth has the same category. If wsteth would be added to the protocol its category would be the one of eth.

`assets_lender` is true if an asset is used to be lent, false otherwise.
For instance, eth will have value true in this map, but feth will have false.

`assets_borrower` is true if an asset is used to be used as a collateral, false otherwise.
For instance, feth will have value true in this map, but eth will have false.

`price_information` is how much 10^18 of a borrow asset is worth on the corresponding lend asset.
So for instance, the feth price field is 10^18, because we consider that 1feth=1eth so 10^18feth = 10^18eth as both eth20s of eth and feth have the same decimal parameters.
If wsteth would be added to the protocol, as 1wsteth = 1.3eth (or something like that), then its price value would be 1.3 * 10^18

`ltv_information` is the ltv of a borrow asset. The scale is from 0 to `LTV_100_PERCENT` defined in `constants.cairo` which corresponds to 100%.

```rust
// Points
points_multiplier: u256,
total_points: u256,
user_points: Map<ContractAddress, u256>,
points_multiplier_per_asset: Map<ContractAddress, u256>,
```

Used to keep tracks of the "points" of the protocol for a future aidrop. Yes it's supposed to be off chain but storage is cheap.

### Public functions of the contract

```rust
// Deposit/Withdraw
fn deposit(ref self: TContractState, token: ContractAddress, amount: u256);
fn withdraw(ref self: TContractState, token: ContractAddress, amount: u256);
```

todo

```rust
// Make/Disable offers
fn make_lend_offer(ref self: TContractState, token: ContractAddress, amount: u256, accepted_collateral: u256, price: Price);
fn disable_lend_offer(ref self: TContractState, id_offer: u64);
fn make_borrow_offer(ref self: TContractState, token: ContractAddress, amount: u256, price: Price);
fn disable_borrow_offer(ref self: TContractState, id_offer: u64);
```

todo

```rust
// Match, Repay, and Liquidate offers
fn match_offer(ref self: TContractState, lend_offer_id: u64, borrow_offer_id: u64, amount: u256);
fn repay_offer(ref self: TContractState, offer_id: u64);
fn liquidate_offer(ref self: TContractState, offer_id: u64);
```

todo

## How are users excepted to use the app:

### Flow of use:

1. Borrowers deposit non yield assets (eg eth) with `deposit`
2. Lenders deposit yield assets (eg Feth, wsteth, etc...) with `deposit`
3. Both borrowers and lenders make offers on the market with `make_lend_offer` and `make_borrow_offer`
4. Anyone can match any compatible offers - usually someone that wants to take an offer will make a correponding offer and immediatly match it with its wanted offer. This is done with `match_offers`
5. Offer are repaid with `repay_offer` or `liquidate_offer`

### The different repayment/liquidation flows:

1. A regular repaid loan:
Only the borrower can repay, and then it just takes the money that the borrower has in the protocol to transfer it to the lender.
The borrower has to repay within the allowed time.
In this case, the lender gets what he lent, and some interest.

2. A liquidation where the borrower still has the money to repay the lender:
In this case, when the liquidate function is called, the lender is repaid with the amount
that the borrower has in the protocol.
So if the loan was 100eth with 200feth collateral, and the borrower has 110eth in the protocol,
then the liquidation do use the 110eth to repay the lender, and the collateral is not touched.
In this case, the lender gets what he lent, and some interest.

3. A liquidation but the borrower doesn't have the money to repay the lender:
Its collateral is transferred to the lender, the value of this collateral isn't recomputed, so the lender can end up with a loss.
The LTV ensures this won't be the case hopefully, but it can happen when yield bearing assets depeg.
So if the loan was 100eth with 200feth collateral, and the borrower has 0eth in the protocol,
all the 200feth is transferred to the lender. If for instance the borrower has 1000feth in the protocol,
only 200feth is transferred to the lender, and the rest is not touched.
In this case, the lender do not get what he lent, but get some collateral instead.

## When do lenders/borrowers lose money:

Users can lose money if the smart contract get hacked.
In this case, all the funds deposited may be lost.
Otherwise, here are the cases where users can lose money:

### Lender

A lender can lose money when a collateral massively depegs.

For instance, if a lender lends 1eth against 2feth, and the value of feth drops to 0,
then the borrower will likely not repay the loan, the lender can liquidate it to
get the 2feth which will be worth 0.
Else, if the collateral doesn't depeg, the lender do not lose money upon liquidation in any circumpstances,
if there is some liquidation, the lender will get in this example 2feth instead of its 1eth+interest,
which is worth more than the 1eth+interest.

If a collateral slightly depegs, eg 1feth was supposed to be worth 1eth but is now worth only 0.8eth,
then the lender still doesn't lose money thanks to the LTV parameter. Right now, it is set to 50%,
so 2feth are required to lend 1eth, and therefore upon liquidation the lender will get 2feth worth 1.6eth
which is larger than its deposit of 1eth

### Borrower

A borrower cannot lose money, when he repays a loan.
If he gets liquidated and the collateral hasn't depeg, then he loses money (which is earnt by the lender as described above).


## Information for auditoooors

### Audit scope:

In scope:
+ lib.cairo: lines 1-422 (422 LOC)
+ utilities.cairo: whole file (102 LOC)
+ datastructure.cairo: whole file (48 LOC)
+ constants.cairo: whole file (41 LOC)

Not in scope:
+ lib.cairo: lines 422-591 - this isn’t used in the contract, only reader functions used in the frontend
+ mock_erc20.cairo: whole file - not used in the contract, only in the tests
+ all the tests: because this is tests

## Assumptions

We assume the erc20 we use aren't malicious, we whitelist each of them a whitelisted erc20 contract cannot be used in the smart contract so we make the assumption that they are not malicious and can re-call the smart contract.

## "Invariant"

Unfortunatly, there is limited tools to verify invariants on starknet, so this section is purely descriptive,
and is not verified by any tool what so ever.

The protocol is permisionned for the assets it allows, both in what can be lent and what can be used as collateral. So if an assets doesn't have a value in the storage `category_information` set, then it cannot be used neither as a lending asset or a collateral. Only the admin address can whitelist tokens.

All the lend offers and borrow offers available to take are exactly all the elements of `lend_offers` and `borrow_offers` of the storage with the field `is_active` set to true.
All the current loans of the protocol are exactly all the elements of `current_matches` of the storage with the field `is_active` set to true.

Only the admin address can modify the information of the following field of the storage
`category_information`,
`assets_lender`,
`assets_borrower`,
`price_information`, and
`ltv_information`.

The sum of all the elements `user_points` of the storage is the value
`total_points` of the storage.

When a loan is made, there is always `maximal_duration > minimal_duration + SECONDS_PER_DAY`, there is at least a full day for the borrower to repay.
This is verified in the function `match_offer` with the call `assert_validity_of_price(price_match);`.

Once an object has a field `is_active` set to false, it cannot be ever resetted it to true. It's excepted, if a user want to re activate an offer he just creates a new one.



## How to run build/tests:

Build: `scarb build`

Run the tests:`snforge test`



# Risks of using the app:

## General risks

The code is not audited. It could have bugs that could result in total loss of funds.

Starknet and cairo are experimental technology. It could have bugs that could result in total loss of funds.

I reserve the right to modify your number of points at anytime.
Maybe there won't be an airdrop.
Points do not entitle you to a potential airdrop.
I reverse the right to ban you from the points program at anytime.

I am not liable of any loss of funds you may incur when using my app.
By interacting with the app you confirm that you won't sue me for loss of funds or anything else related to my app.

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