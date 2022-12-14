// SPDX-License-Identifier: MIT
pragma solidity ~0.7.6;
pragma abicoder v2;
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.4-solc-0.7/contracts/token/ERC20/ERC20.sol";

struct WalletFee {
    address wallet;
    uint fee;
}

interface IMultipleArbitrableTransaction {
    /** @dev Create a ETH-based transaction.
     *  @param _timeoutPayment Time after which a party can automatically execute the arbitrable transaction.
     *  @param _sender The recipient of the transaction.
     *  @param _receiver The recipient of the transaction.
     *  @param _metaEvidence Link to the meta-evidence.
     *  @param _adminWallet Admin fee wallet.
     *  @param _adminFeeAmount Admin fee amount.
     *  @param _burnWallet Burn fee wallet.
     *  @param _burnFeeAmount Burn fee amount.
     *  @return transactionID The index of the transaction.
     **/
    function createETHTransaction(
        uint _timeoutPayment,
        address payable _sender,
        address payable _receiver,
        string memory _metaEvidence,
        uint256 _amount,
        address payable _adminWallet,
        uint _adminFeeAmount,
        address payable _burnWallet,
        uint _burnFeeAmount
    ) external payable returns (uint transactionID);

    /** @dev Create a token-based transaction.
     *  @param _timeoutPayment Time after which a party can automatically execute the arbitrable transaction.
     *  @param _sender The recipient of the transaction.
     *  @param _receiver The recipient of the transaction.
     *  @param _metaEvidence Link to the meta-evidence.
     *  @param _tokenAddress Address of token used for transaction.
     *  @param _adminWallet Admin fee wallet.
     *  @param _adminFeeAmount Admin fee amount.
     *  @param _burnWallet Burn fee wallet.
     *  @param _burnFeeAmount Burn fee amount.
     *  @return transactionID The index of the transaction.
     **/
    function createTokenTransaction(
        uint _timeoutPayment,
        address payable _sender,
        address payable _receiver,
        string memory _metaEvidence,
        uint256 _amount,
        address _tokenAddress,
        address payable _adminWallet,
        uint _adminFeeAmount,
        address payable _burnWallet,
        uint _burnFeeAmount
    ) external payable returns (uint transactionID);
}