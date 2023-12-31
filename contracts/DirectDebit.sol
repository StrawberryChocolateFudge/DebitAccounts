// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./Errors.sol";

//   o__ __o         o                                        o           o__ __o                     o             o     o
//  <|     v\      _<|>_                                     <|>         <|     v\                   <|>          _<|>_  <|>
//  / \     <\                                               < >         / \     <\                  / >                 < >
//  \o/       \o     o    \o__ __o     o__  __o       __o__   |          \o/       \o     o__  __o   \o__ __o       o     |
//   |         |>   <|>    |     |>   /v      |>     />  \    o__/_       |         |>   /v      |>   |     v\     <|>    o__/_
//  / \       //    / \   / \   < >  />      //    o/         |          / \       //   />      //   / \     <\    / \    |
//  \o/      /      \o/   \o/        \o    o/     <|          |          \o/      /     \o    o/     \o/      /    \o/    |
//   |      o        |     |          v\  /v __o   \\         o           |      o       v\  /v __o   |      o      |     o
//  / \  __/>       / \   / \          <\/> __/>    _\o__</   <\__       / \  __/>        <\/> __/>  / \  __/>     / \    <\__

// This contract  implements direct debit using crypto notes
// The user can create a Note off-chain that is stored encrypted inside the smart contract
// Then create an account which contains commitment from the note, this account can be topped up as needed.
// The Note can be used off-chain to compute proofs that allow a payee to withdraw funds from this account.

// The data for the accounts is stored in this struct
struct AccountData {
    bool active;
    address creator;
    IERC20 token;
    uint256 balance;
}

/*
  The the debit history is used for tracking payment intents and nullifying them!
  it tracks withdrawalCount and the lastDate the proof was used for withdrawing value
*/
struct PaymentIntentHistory {
    bool isNullified;
    uint256 withdrawalCount;
    uint256 lastDate;
}

// The interface of the Verifier contract generated from the circuit
interface IVerifier {
    function verifyProof(
        uint256[2] memory a,
        uint256[2][2] memory b,
        uint256[2] memory c,
        uint256[6] memory _input
    ) external returns (bool);
}

/**
   The direct debit contract is a parent contract that implements the basic functionality to create debit accounts
   Deploy only the ConnectedWallets or the VirtualAccounts contracts
 */
abstract contract DirectDebit is
    ReentrancyGuard,
    DirectDebitErrors,
    DirectDebitEvents,
    Pausable,
    Ownable
{
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    IVerifier public immutable verifier; // The verifier address

    /**
     1% fee sent to the deployer of this contract on all transactions. 
     We divide the payout with the ownerFeeDivider
    */
    uint256 public ownerFeeDivider = 100;

    /**
    The commitments for each address are stored in a mapping for easy access
     */
    mapping(address => mapping(uint256 => bytes32)) public commitments;

    /**
    The counter is used to access the account commitment index
     */
    mapping(address => uint256) public accountCounter;

    /* PaymentIntent Hashes are keys to the history of payments
     Each payment intent has a unique hash thanks to the nonce added to the nullifier secret nullifier
     The mapping tracks how many times a payment intent was used and will nullify future payments
     */
    mapping(bytes32 => PaymentIntentHistory) public paymentIntents;

    /*
       accounts are keys to Account data
    */
    mapping(bytes32 => AccountData) public accounts;

    /*
       The Secret notes are encrypted and stored on-chain, Insipred by Tornado Cash note accounts
       The note's are encrypted with symmetric and asymmetric encryption before stored on chain using a password and an identity provider's public key.
       These notes are used to compute the ZKP (Payment Intent) off-chain that can be used to debit an account
    */
    mapping(bytes32 => string) public encryptedNotes;

    /*
      The relayers approved to call DirectDebit, this was added for the AVAX deployment
     */

    mapping(address => bool) public approvedRelayers;

    /**
        @dev : the constructor
        @param _verifier is the address of SNARK verifier contract        
    */

    constructor(IVerifier _verifier) {
        verifier = _verifier;
    }

    /**
     @dev calculate the fee used for the payment
     @param amount is the debited amount
   */
    function calculateFee(
        uint256 amount
    ) public view returns (uint256 ownerFee, uint256 payment) {
        ownerFee = amount.div(ownerFeeDivider);
        payment = amount.sub(ownerFee);
    }

    /**
       @dev update the fee calculation
       @param newFeeDivider is the variable used for calculating the fee
     */
    function updateFee(uint256 newFeeDivider) external onlyOwner {
        ownerFeeDivider = newFeeDivider;
    }

    /**
      The Owner can pause and unpause the contract to stop pull payments from it, the withdrawals and wallet disconnecting will still work!
      This is a safety mechanism, in the event of a decryption key leak, an attacker will be able to decrypt the asymmetric encrypted crypto notes,
      However the attacker still needs time to brute force passwords and won't be able to drain balances fast!
      The owner of the smart contract can pause all directdebit and let the account creators disconnect/withdraw their funds.
      Incidents/unauthorized access can be detected automaticly as successful directdebit transactions not sent by the relayer.
     */
    function togglePause() external onlyOwner {
        if (paused()) {
            _unpause();
        } else {
            _pause();
        }
    }

    /**
     The owner must approve a relayer to call direct debit. This is an extra security layer added to the contracts
     */
    function approveRelayer(address _addr, bool setTo) external onlyOwner {
        approvedRelayers[_addr] = setTo;
    }

    /**
      A function that allows direct debit with a reusable proof
      N times to M address with L max amount that can be withdrawn
      The proof and public inputs are the PaymentIntent
      @param proof contains the zkSnark
      @param hashes are [0] = paymentIntent [1] = commitment
      @param payee is the account recieving the payment
      @param debit[4] are [0] = max debit amount, [1] = debitTimes, [2] = debitInterval, [3] = payment amount. 
      Last param is not used in the circuit but it must be smaller than the max debit amount
      By using a separate max debit amount and a payment amount we can create dynamic subscriptions, where the final price varies 
      but can't be bigger than the allowed amount!
      This function can be paused by the owner to disable it!
    */
    function directdebit(
        uint256[8] calldata proof,
        bytes32[2] calldata hashes,
        address payee,
        uint256[4] calldata debit
    ) external nonReentrant whenNotPaused {
        if (!approvedRelayers[msg.sender]) revert OnlyApprovedRelayer();
        _verifyPaymentIntent(proof, hashes, payee, debit);
        _processPaymentIntent(hashes, payee, debit);
    }

    /**
      Cancels the payment intent! The caller must be the creator of the account and must have the zksnark (paymentIntent)
      The zksnark is needed so the Payment Intent can be cancelled before it's used and for that we need proof that it exists!
      @param proof is the snark
      @param hashes are [0] = paymentIntent [1] = commitment
      @param payee is the account recieving the payment
      @param debit [4] are [0] = max debit amount, [1] = debitTimes, [2] = debitInterval, [3] = payment amount. 
      In case of cancellation the 4th value in the debit array can be arbitrary. It is kept here to keep the verifier function's interface
     */
    function cancelPaymentIntent(
        uint256[8] calldata proof,
        bytes32[2] calldata hashes,
        address payee,
        uint256[4] calldata debit
    ) external {
        if (!_verifyProof(proof, hashes, payee, debit)) revert InvalidProof();
        if (msg.sender != accounts[hashes[1]].creator && msg.sender != payee)
            revert OnlyRelatedPartiesCanCancel();
        paymentIntents[hashes[0]].isNullified = true;
        emit PaymentIntentCancelled(hashes[1], hashes[0], payee);
    }

    /**
       The direct debit transaction is verified using these conditions!
       The verification is slightly different for child contracts so then need to implement it.
    */

    function _verifyPaymentIntent(
        uint256[8] calldata proof,
        bytes32[2] calldata hashes,
        address payee,
        uint256[4] calldata debit
    ) internal virtual;

    function _verifyProof(
        uint256[8] calldata proof,
        bytes32[2] calldata hashes,
        address payee,
        uint256[4] calldata debit
    ) internal returns (bool) {
        return
            verifier.verifyProof(
                [proof[0], proof[1]],
                [[proof[2], proof[3]], [proof[4], proof[5]]],
                [proof[6], proof[7]],
                [
                    uint256(hashes[0]),
                    uint256(hashes[1]),
                    uint256(uint160(payee)),
                    uint256(debit[0]),
                    uint256(debit[1]),
                    uint256(debit[2])
                ]
            );
    }

    /**
      This function will process the payment intent and trigger the withdrawals
      It sends rewards to the relayers or cashback to the account user!
    */

    function _processPaymentIntent(
        bytes32[2] calldata hashes,
        address payee,
        uint256[4] calldata debit
    ) internal {
        // Calculate the fee
        (uint256 ownerFee, uint256 payment) = calculateFee(debit[3]);

        // Add a debit time to the nullifier
        paymentIntents[hashes[0]].withdrawalCount += 1;
        paymentIntents[hashes[0]].lastDate = block.timestamp;

        // Process the withdraw
        if (address(accounts[hashes[1]].token) != address(0)) {
            _processTokenWithdraw(hashes[1], payee, payment);
            _processTokenWithdraw(hashes[1], payable(owner()), ownerFee);
        } else {
            // Transfer the eth
            _processEthWithdraw(hashes[1], payee, payment);
            // Send the fee to the owner
            _processEthWithdraw(hashes[1], payable(owner()), ownerFee);
        }

        emit AccountDebited(hashes[1], payee, payment);
    }

    /*
       Process the token withdrawal and decrease the account balance
    */

    function _processTokenWithdraw(
        bytes32 commitment,
        address payee,
        uint256 payment
    ) internal virtual;

    /**
      Process the eth withdraw and decrease the account balance
    */

    function _processEthWithdraw(
        bytes32 commitment,
        address payee,
        uint256 payment
    ) internal virtual;

    /**
    A view function to get and display the account's balance
    This is useful when the account balance is calculated from external wallet's balance!
     */
    function getAccount(
        bytes32 commitment
    ) external view virtual returns (AccountData memory);
}
