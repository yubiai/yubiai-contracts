// SPDX-License-Identifier: MIT
pragma solidity ~0.7.6;
pragma abicoder v2;
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.4-solc-0.7/contracts/token/ERC20/ERC20.sol";

struct WalletFee {
    address wallet;
    uint fee;
}

interface IMultipleArbitrableTransaction {
    /** @dev Create a transaction.
     *  @param _timeoutPayment Time after which a party can automatically execute the arbitrable transaction.
     *  @param _sender The recipient of the transaction.
     *  @param _receiver The recipient of the transaction.
     *  @param _metaEvidence Link to the meta-evidence.
     *  @param _tokenAddress Address of token used for transaction.
     *  @param _amount Amount of the the transaction.
     *  @param _adminWallet Admin fee wallet.
     *  @param _adminFeeAmount Admin fee amount.
     *  @param _burnWallet Burn fee wallet.
     *  @param _burnFeeAmount Burn fee amount.
     *  @return transactionID The index of the transaction.
     **/
    function createTransaction(
        uint _timeoutPayment,
        address _sender,
        address _receiver,
        string memory _metaEvidence,
        address _tokenAddress,
        uint _amount,
        address _adminWallet,
        uint _adminFeeAmount,
        address _burnWallet,
        uint _burnFeeAmount
    ) external payable returns (uint transactionID);
}