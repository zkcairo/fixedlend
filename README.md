# README

FixedLend, a p2p lending app on starknet for yield trading/hedging.

## Flow of use:

1. Borrowers deposit non yield assets (eg eth) with `deposit`
2. Lenders deposit yield assets (eg Feth, wsteth, etc...) with `deposit`
3. Both borrowers and lenders make offers on the market with `make_lend_offer` and `make_borrow_offer`
4. Anyone can match any compatible offers - usually someone that wants to take an offer will make a correponding offer and immediatly match it with its wanted offer. This is done with `match_offers`
5. Offer are repaid with `repay_offer` or `liquidate_offer`

## The different repayment flows:

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

## Known issues:

If assets depeg then users are rekt, eg a lend of eth with feth as collateral, if feth depegs, then the lender can end up with a loss.

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