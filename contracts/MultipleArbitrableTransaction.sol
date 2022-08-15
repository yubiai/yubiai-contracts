// SPDX-License-Identifier: MIT
pragma solidity ~0.4.24;

import "https://github.com/kleros/kleros-interaction/blob/master/contracts/standard/arbitration/MultipleArbitrableTransaction.sol";
import "./ERC20.sol";

contract YubiaiMultipleArbitrableTransaction is MultipleArbitrableTransaction {
    ExtendedTransaction[] public transactions;

    struct WalletFee {
        address wallet;
        uint fee;
    }

    struct ExtendedTransaction {
        IERC20 token;
        Transaction _transaction;
        WalletFee adminFee;
        WalletFee burnFee;
    }

    constructor (
        Arbitrator _arbitrator,
        bytes _arbitratorExtraData,
        uint _feeTimeout
    ) MultipleArbitrableTransaction(_arbitrator, _arbitratorExtraData, _feeTimeout) public { }

    function receive() external payable { }

    function compareStrings(string memory a, string memory b) private pure returns (bool) {
        return (keccak256(abi.encodePacked((a))) == keccak256(abi.encodePacked((b))));
    }

    function performTransactionFee(ExtendedTransaction memory transaction, string memory mode) private {
        if (compareStrings(mode, "pay")) {
            transaction.adminFee.wallet.transfer(transaction.adminFee.fee);
            transaction.burnFee.wallet.transfer(transaction.burnFee.fee);
        } else {
            transaction._transaction.sender.transfer(transaction.adminFee.fee);
            transaction._transaction.sender.transfer(transaction.burnFee.fee);
        }
    }

    function getRawTransaction(
        address _sender,
        address _receiver
    ) private view returns (Transaction) {
        return Transaction({
            sender: _sender,
            receiver: _receiver,
            amount: 0,
            timeoutPayment: 0,
            disputeId: 0,
            senderFee: 0,
            receiverFee: 0,
            lastInteraction: now,
            status: Status.NoDispute
        });
    }

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
        string _metaEvidence,
        address _tokenAddress,
        uint _amount,
        address _adminWallet,
        uint _adminFeeAmount,
        address _burnWallet,
        uint _burnFeeAmount
    ) public payable returns (uint transactionID) {
        WalletFee memory _adminFee = WalletFee(_adminWallet, _adminFeeAmount);
        WalletFee memory _burnFee = WalletFee(_burnWallet, _burnFeeAmount);
        Transaction memory _rawTransaction = getRawTransaction(_sender, _receiver);
        _rawTransaction.amount = _amount;
        _rawTransaction.timeoutPayment = _timeoutPayment;

        IERC20 _token;
        if (address(_tokenAddress) != address(0)) {
            _token = IERC20(_tokenAddress);
            // Transfers token from sender wallet to contract.
            require(
                _token.transferFrom(msg.sender, address(this), _amount),
                "Sender does not have enough approved funds."
            );
        }

        ExtendedTransaction memory _transaction = ExtendedTransaction({
            token: _token,
            _transaction: _rawTransaction,
            adminFee: _adminFee,
            burnFee: _burnFee
        });
        transactions.push(_transaction);
        emit MetaEvidence(transactions.length - 1, _metaEvidence);

        return transactions.length - 1;
    }

    /** @dev Pay receiver. To be called if the good or service is provided.
     *  @param _transactionID The index of the transaction.
     *  @param _amount Amount to pay in wei.
     */
    function pay(uint _transactionID, uint _amount) public {
        ExtendedTransaction storage transaction = transactions[_transactionID];
        require(transaction._transaction.sender == msg.sender, "The caller must be the sender.");
        require(transaction._transaction.status == Status.NoDispute, "The transaction shouldn't be disputed.");
        require(_amount <= transaction._transaction.amount, "The amount paid has to be less than or equal to the transaction.");

        transaction._transaction.receiver.transfer(_amount);
        transaction._transaction.amount -= _amount;
        performTransactionFee(transaction, "pay");
        emit Payment(_transactionID, _amount, msg.sender);
    }

    /** @dev Reimburse sender. To be called if the good or service can't be fully provided.
     *  @param _transactionID The index of the transaction.
     *  @param _amountReimbursed Amount to reimburse in wei.
     */
    function reimburse(uint _transactionID, uint _amountReimbursed) public {
        ExtendedTransaction storage transaction = transactions[_transactionID];
        require(transaction._transaction.receiver == msg.sender, "The caller must be the receiver.");
        require(transaction._transaction.status == Status.NoDispute, "The transaction shouldn't be disputed.");
        require(_amountReimbursed <= transaction._transaction.amount, "The amount reimbursed has to be less or equal than the transaction.");

        transaction._transaction.sender.transfer(_amountReimbursed);
        transaction._transaction.amount -= _amountReimbursed;
        performTransactionFee(transaction, "reimburse");
        emit Payment(_transactionID, _amountReimbursed, msg.sender);
    }

    /** @dev Transfer the transaction's amount to the receiver if the timeout has passed.
     *  @param _transactionID The index of the transaction.
     */
    function executeTransaction(uint _transactionID) public {
        ExtendedTransaction storage transaction = transactions[_transactionID];
        require(now - transaction._transaction.lastInteraction >= transaction._transaction.timeoutPayment, "The timeout has not passed yet.");
        require(transaction._transaction.status == Status.NoDispute, "The transaction shouldn't be disputed.");

        transaction._transaction.receiver.transfer(transaction._transaction.amount);
        transaction._transaction.amount = 0;
        performTransactionFee(transaction, "pay");

        transaction._transaction.status = Status.Resolved;
    }

    /** @dev Reimburse sender if receiver fails to pay the fee.
     *  @param _transactionID The index of the transaction.
     */
    function timeOutBySender(uint _transactionID) public {
        ExtendedTransaction storage transaction = transactions[_transactionID];

        require(transaction._transaction.status == Status.WaitingReceiver, "The transaction is not waiting on the receiver.");
        require(now - transaction._transaction.lastInteraction >= feeTimeout, "Timeout time has not passed yet.");

        executeRuling(_transactionID, SENDER_WINS);
    }

    /** @dev Pay receiver if sender fails to pay the fee.
     *  @param _transactionID The index of the transaction.
     */
    function timeOutByReceiver(uint _transactionID) public {
        ExtendedTransaction storage transaction = transactions[_transactionID];

        require(transaction._transaction.status == Status.WaitingSender, "The transaction is not waiting on the sender.");
        require(now - transaction._transaction.lastInteraction >= feeTimeout, "Timeout time has not passed yet.");

        executeRuling(_transactionID, RECEIVER_WINS);
    }

    /** @dev Pay the arbitration fee to raise a dispute. To be called by the sender. UNTRUSTED.
     *  Note that the arbitrator can have createDispute throw, which will make this function throw and therefore lead to a party being timed-out.
     *  This is not a vulnerability as the arbitrator can rule in favor of one party anyway.
     *  @param _transactionID The index of the transaction.
     */
    function payArbitrationFeeBySender(uint _transactionID) public payable {
        ExtendedTransaction storage transaction = transactions[_transactionID];
        uint arbitrationCost = arbitrator.arbitrationCost(arbitratorExtraData);

        require(transaction._transaction.status < Status.DisputeCreated, "Dispute has already been created or because the transaction has been executed.");
        require(msg.sender == transaction._transaction.sender, "The caller must be the sender.");

        transaction._transaction.senderFee += msg.value;
        // Require that the total pay at least the arbitration cost.
        require(transaction._transaction.senderFee >= arbitrationCost, "The sender fee must cover arbitration costs.");

        transaction._transaction.lastInteraction = now;

        // The receiver still has to pay. This can also happen if he has paid, but arbitrationCost has increased.
        if (transaction._transaction.receiverFee < arbitrationCost) {
            transaction._transaction.status = Status.WaitingReceiver;
            emit HasToPayFee(_transactionID, Party.Receiver);
        } else { // The receiver has also paid the fee. We create the dispute.
            raiseDispute(_transactionID, arbitrationCost);
            performTransactionFee(transaction, "reimburse");
        }
    }

    /** @dev Pay the arbitration fee to raise a dispute. To be called by the receiver. UNTRUSTED.
     *  Note that this function mirrors payArbitrationFeeBySender.
     *  @param _transactionID The index of the transaction.
     */
    function payArbitrationFeeByReceiver(uint _transactionID) public payable {
        ExtendedTransaction storage transaction = transactions[_transactionID];
        uint arbitrationCost = arbitrator.arbitrationCost(arbitratorExtraData);

        require(transaction._transaction.status < Status.DisputeCreated, "Dispute has already been created or because the transaction has been executed.");
        require(msg.sender == transaction._transaction.receiver, "The caller must be the receiver.");

        transaction._transaction.receiverFee += msg.value;
        // Require that the total paid to be at least the arbitration cost.
        require(transaction._transaction.receiverFee >= arbitrationCost, "The receiver fee must cover arbitration costs.");

        transaction._transaction.lastInteraction = now;
        // The sender still has to pay. This can also happen if he has paid, but arbitrationCost has increased.
        if (transaction._transaction.senderFee < arbitrationCost) {
            transaction._transaction.status = Status.WaitingSender;
            emit HasToPayFee(_transactionID, Party.Sender);
        } else { // The sender has also paid the fee. We create the dispute.
            raiseDispute(_transactionID, arbitrationCost);
        }
    }

    /** @dev Create a dispute. UNTRUSTED.
     *  @param _transactionID The index of the transaction.
     *  @param _arbitrationCost Amount to pay the arbitrator.
     */
    function raiseDispute(uint _transactionID, uint _arbitrationCost) internal {
        ExtendedTransaction storage transaction = transactions[_transactionID];
        transaction._transaction.status = Status.DisputeCreated;
        transaction._transaction.disputeId = arbitrator.createDispute.value(_arbitrationCost)(AMOUNT_OF_CHOICES, arbitratorExtraData);
        disputeIDtoTransactionID[transaction._transaction.disputeId] = _transactionID;
        emit Dispute(arbitrator, transaction._transaction.disputeId, _transactionID, _transactionID);

        // Refund sender if it overpaid.
        if (transaction._transaction.senderFee > _arbitrationCost) {
            uint extraFeeSender = transaction._transaction.senderFee - _arbitrationCost;
            transaction._transaction.senderFee = _arbitrationCost;
            transaction._transaction.sender.transfer(extraFeeSender);
        }

        // Refund receiver if it overpaid.
        if (transaction._transaction.receiverFee > _arbitrationCost) {
            uint extraFeeReceiver = transaction._transaction.receiverFee - _arbitrationCost;
            transaction._transaction.receiverFee = _arbitrationCost;
            transaction._transaction.receiver.transfer(extraFeeReceiver);
        }
    }

    /** @dev Submit a reference to evidence. EVENT.
     *  @param _transactionID The index of the transaction.
     *  @param _evidence A link to an evidence using its URI.
     */
    function submitEvidence(uint _transactionID, string memory _evidence) public {
        ExtendedTransaction storage transaction = transactions[_transactionID];
        require(
            msg.sender == transaction._transaction.sender || msg.sender == transaction._transaction.receiver,
            "The caller must be the sender or the receiver."
        );
        require(
            transaction._transaction.status < Status.Resolved,
            "Must not send evidence if the dispute is resolved."
        );

        emit Evidence(arbitrator, _transactionID, msg.sender, _evidence);
    }

    /** @dev Appeal an appealable ruling.
     *  Transfer the funds to the arbitrator.
     *  Note that no checks are required as the checks are done by the arbitrator.
     *  @param _transactionID The index of the transaction.
     */
    function appeal(uint _transactionID) public payable {
        ExtendedTransaction storage transaction = transactions[_transactionID];

        arbitrator.appeal.value(msg.value)(transaction._transaction.disputeId, arbitratorExtraData);
    }


    /** @dev Give a ruling for a dispute. Must be called by the arbitrator.
     *  The purpose of this function is to ensure that the address calling it has the right to rule on the contract.
     *  @param _disputeID ID of the dispute in the Arbitrator contract.
     *  @param _ruling Ruling given by the arbitrator. Note that 0 is reserved for "Not able/wanting to make a decision".
     */
    function rule(uint _disputeID, uint _ruling) public {
        super.rule(_disputeID, _ruling);
    }

    /** @dev Execute a ruling of a dispute. It reimburses the fee to the winning party.
     *  @param _transactionID The index of the transaction.
     *  @param _ruling Ruling given by the arbitrator. 1 : Reimburse the receiver. 2 : Pay the sender.
     */
    function executeRuling(uint _transactionID, uint _ruling) internal {
        super.executeRuling(_transactionID, _ruling);
    }

    // **************************** //
    // *     Constant getters     * //
    // **************************** //

    /** @dev Getter to know the count of transactions.
     *  @return countTransactions The count of transactions.
     */
    function getCountTransactions() public view returns (uint countTransactions) {
        return super.getCountTransactions();
    }

    /** @dev Get IDs for transactions where the specified address is the receiver and/or the sender.
     *  This function must be used by the UI and not by other smart contracts.
     *  Note that the complexity is O(t), where t is amount of arbitrable transactions.
     *  @param _address The specified address.
     *  @return transactionIDs The transaction IDs.
     */
    function getTransactionIDsByAddress(address _address) public view returns (uint[] transactionIDs) {
        return super.getTransactionIDsByAddress(_address);
    }
}