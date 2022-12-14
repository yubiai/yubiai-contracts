// SPDX-License-Identifier: MIT
pragma solidity ~0.7.6;
pragma abicoder v2;

import "./deps/Arbitrator.sol";
import "./deps/IArbitrable.sol";
import "./ERC20.sol";

contract YubiaiMultipleArbitrableTransaction is IArbitrable {
    // **************************** //
    // *    Contract variables    * //
    // **************************** //

    uint8 constant AMOUNT_OF_CHOICES = 2;
    uint8 constant SENDER_WINS = 1;
    uint8 constant RECEIVER_WINS = 2;

    enum Party {Sender, Receiver}
    enum Status {NoDispute, WaitingSender, WaitingReceiver, DisputeCreated, Resolved}

    struct WalletFee {
        address payable wallet;
        uint fee;
    }

    struct Transaction {
        address payable sender;
        address payable receiver;
        uint amount;
        uint timeoutPayment; // Time in seconds after which the transaction can be automatically executed if not disputed.
        uint disputeId; // If dispute exists, the ID of the dispute.
        uint senderFee; // Total fees paid by the sender.
        uint receiverFee; // Total fees paid by the receiver.
        uint lastInteraction; // Last interaction for the dispute procedure.
        Status status;
    }

    struct ExtendedTransaction {
        address token;
        Transaction _transaction;
        WalletFee adminFee;
        WalletFee burnFee;
    }

    ExtendedTransaction[] public transactions;
    bytes public arbitratorExtraData; // Extra data to set up the arbitration.
    Arbitrator public arbitrator; // Address of the arbitrator contract.
    uint public feeTimeout; // Time in seconds a party can take to pay arbitration fees before being considered unresponding and lose the dispute.


    mapping (uint => uint) public disputeIDtoTransactionID; // One-to-one relationship between the dispute and the transaction.

    // **************************** //
    // *          Events          * //
    // **************************** //

    /** @dev To be emitted when a party pays or reimburses the other.
     *  @param _transactionID The index of the transaction.
     *  @param _amount The amount paid.
     *  @param _party The party that paid.
     */
    event Payment(uint indexed _transactionID, uint _amount, address _party);

    /** @dev Indicate that a party has to pay a fee or would otherwise be considered as losing.
     *  @param _transactionID The index of the transaction.
     *  @param _party The party who has to pay.
     */
    event HasToPayFee(uint indexed _transactionID, Party _party);

    /** @dev To be raised when a ruling is given.
     *  @param _arbitrator The arbitrator giving the ruling.
     *  @param _disputeID ID of the dispute in the Arbitrator contract.
     *  @param _ruling The ruling which was given.
     */
    // event Ruling(Arbitrator indexed _arbitrator, uint indexed _disputeID, uint _ruling);

    /** @dev Emitted when a transaction is created.
     *  @param _transactionID The index of the transaction.
     *  @param _sender The address of the sender.
     *  @param _receiver The address of the receiver.
     *  @param _amount The initial amount in the transaction.
     */
    event TransactionCreated(uint _transactionID, address indexed _sender, address indexed _receiver, uint _amount);

    // **************************** //
    // *    Arbitrable functions  * //
    // *    Modifying the state   * //
    // **************************** //

    /** @dev Constructor.
     *  @param _arbitrator The arbitrator of the contract.
     *  @param _arbitratorExtraData Extra data for the arbitrator.
     *  @param _feeTimeout Arbitration fee timeout for the parties.
     */
    constructor (
        Arbitrator _arbitrator,
        bytes memory _arbitratorExtraData,
        uint _feeTimeout
    ) {
        arbitrator = _arbitrator;
        arbitratorExtraData = _arbitratorExtraData;
        feeTimeout = _feeTimeout;
    }

    receive() external payable { }

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

    function handleTransactionTransfer(
        uint _transactionID,
        address payable destination,
        uint amount,
        uint finalAmount,
        bool isToken,
        string memory feeMode,
        bool emitPayment
    ) public {
        ExtendedTransaction memory transaction = transactions[_transactionID];
        if (isToken) {
            require(
                IERC20(transaction.token).transfer(destination, amount),
                "The `transfer` function must not fail."
            );
        } else {
            destination.transfer(amount);
        }
        transaction._transaction.amount = finalAmount;
        performTransactionFee(transaction, feeMode);

        if (emitPayment) {
            emit Payment(_transactionID, amount, msg.sender);
        }
    }

    function initTransaction(
        address payable _sender,
        address payable _receiver
    ) private view returns (Transaction memory) {
        return Transaction({
            sender: _sender,
            receiver: _receiver,
            amount: 0,
            timeoutPayment: 0,
            disputeId: 0,
            senderFee: 0,
            receiverFee: 0,
            lastInteraction: block.timestamp,
            status: Status.NoDispute
        });
    }

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
    ) public payable returns (uint transactionID) {
        require(
            _amount + _burnFeeAmount + _adminFeeAmount == msg.value,
            "Fees or amounts don't match with payed amount."
        );
        address(this).transfer(msg.value);

        return createTransaction(
            _timeoutPayment,
            _sender,
            _receiver,
            _metaEvidence,
            _amount,
            address(0),
            _adminWallet,
            _adminFeeAmount,
            _burnWallet,
            _burnFeeAmount
        );
    }

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
    ) public payable returns (uint transactionID) {
        IERC20 token = IERC20(_tokenAddress);
        // Transfers token from sender wallet to contract. Permit before transfer
        require(
            token.transferFrom(msg.sender, address(this), _amount),
            "Sender does not have enough approved funds."
        );
        require(
            _adminFeeAmount + _burnFeeAmount == msg.value,
            "Fees don't match with payed amount"
        );

        return createTransaction(
            _timeoutPayment,
            _sender,
            _receiver,
            _metaEvidence,
            _amount,
            _tokenAddress,
            _adminWallet,
            _adminFeeAmount,
            _burnWallet,
            _burnFeeAmount
        );
    }

    function createTransaction(
        uint _timeoutPayment,
        address payable _sender,
        address payable _receiver,
        string memory _metaEvidence,
        uint256 _amount,
        address _token,
        address payable _adminWallet,
        uint _adminFeeAmount,
        address payable _burnWallet,
        uint _burnFeeAmount
    ) private returns (uint transactionID) {
        WalletFee memory _adminFee = WalletFee(_adminWallet, _adminFeeAmount);
        WalletFee memory _burnFee = WalletFee(_burnWallet, _burnFeeAmount);
        Transaction memory _rawTransaction = initTransaction(_sender, _receiver);

        _rawTransaction.amount = _amount;
        _rawTransaction.timeoutPayment = _timeoutPayment;

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

        handleTransactionTransfer(
            _transactionID,
            transaction._transaction.receiver,
            _amount,
            _amount,
            transaction.token != address(0),
            "pay",
            true
        );
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

        handleTransactionTransfer(
            _transactionID,
            transaction._transaction.sender,
            _amountReimbursed,
            _amountReimbursed,
            transaction.token != address(0),
            "reimburse",
            true
        );
    }

    /** @dev Transfer the transaction's amount to the receiver if the timeout has passed.
     *  @param _transactionID The index of the transaction.
     */
    function executeTransaction(uint _transactionID) public {
        ExtendedTransaction storage transaction = transactions[_transactionID];
        require(block.timestamp - transaction._transaction.lastInteraction >= transaction._transaction.timeoutPayment, "The timeout has not passed yet.");
        require(transaction._transaction.status == Status.NoDispute, "The transaction shouldn't be disputed.");

        handleTransactionTransfer(
            _transactionID,
            transaction._transaction.receiver,
            transaction._transaction.amount,
            0,
            transaction.token != address(0),
            "pay",
            false
        );

        transaction._transaction.status = Status.Resolved;
    }

    /** @dev Reimburse sender if receiver fails to pay the fee.
     *  @param _transactionID The index of the transaction.
     */
    function timeOutBySender(uint _transactionID) public {
        ExtendedTransaction storage transaction = transactions[_transactionID];

        require(transaction._transaction.status == Status.WaitingReceiver, "The transaction is not waiting on the receiver.");
        require(block.timestamp - transaction._transaction.lastInteraction >= feeTimeout, "Timeout time has not passed yet.");

        executeRuling(_transactionID, SENDER_WINS);
    }

    /** @dev Pay receiver if sender fails to pay the fee.
     *  @param _transactionID The index of the transaction.
     */
    function timeOutByReceiver(uint _transactionID) public {
        ExtendedTransaction storage transaction = transactions[_transactionID];

        require(transaction._transaction.status == Status.WaitingSender, "The transaction is not waiting on the sender.");
        require(block.timestamp - transaction._transaction.lastInteraction >= feeTimeout, "Timeout time has not passed yet.");

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

        transaction._transaction.lastInteraction = block.timestamp;

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

        transaction._transaction.lastInteraction = block.timestamp;
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
        transaction._transaction.disputeId = arbitrator.createDispute{value: _arbitrationCost}(AMOUNT_OF_CHOICES, arbitratorExtraData);
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
        arbitrator.appeal{value: msg.value}(transaction._transaction.disputeId, arbitratorExtraData);
    }

    /** @dev Give a ruling for a dispute. Must be called by the arbitrator.
     *  The purpose of this function is to ensure that the address calling it has the right to rule on the contract.
     *  @param _disputeID ID of the dispute in the Arbitrator contract.
     *  @param _ruling Ruling given by the arbitrator. Note that 0 is reserved for "Not able/wanting to make a decision".
     */
    function rule(uint _disputeID, uint _ruling) override public {
        uint transactionID = disputeIDtoTransactionID[_disputeID];
        ExtendedTransaction storage transaction = transactions[transactionID];
        require(msg.sender == address(arbitrator), "The caller must be the arbitrator.");
        require(transaction._transaction.status == Status.DisputeCreated, "The dispute has already been resolved.");

        emit Ruling(Arbitrator(msg.sender), _disputeID, _ruling);

        executeRuling(transactionID, _ruling);
    }

    /** @dev Execute a ruling of a dispute. It reimburses the fee to the winning party.
     *  @param _transactionID The index of the transaction.
     *  @param _ruling Ruling given by the arbitrator. 1 : Reimburse the receiver. 2 : Pay the sender.
     */
    function executeRuling(uint _transactionID, uint _ruling) internal {
        ExtendedTransaction storage transaction = transactions[_transactionID];
        require(_ruling <= AMOUNT_OF_CHOICES, "Invalid ruling.");

        // Give the arbitration fee back.
        // Note that we use send to prevent a party from blocking the execution.
        /* TODO: Check how to handle fee */
        if (_ruling == SENDER_WINS) {
            transaction._transaction.sender.transfer(transaction._transaction.senderFee + transaction._transaction.amount);
            performTransactionFee(transaction, "reimburse");
        } else if (_ruling == RECEIVER_WINS) {
            transaction._transaction.receiver.transfer(transaction._transaction.receiverFee + transaction._transaction.amount);
            performTransactionFee(transaction, "pay");
        } else {
            uint split_amount = (transaction._transaction.senderFee + transaction._transaction.amount) / 2;
            transaction._transaction.sender.transfer(split_amount);
            transaction._transaction.receiver.transfer(split_amount);
            performTransactionFee(transaction, "reimburse");
        }

        transaction._transaction.amount = 0;
        transaction._transaction.senderFee = 0;
        transaction._transaction.receiverFee = 0;
        transaction._transaction.status = Status.Resolved;
    }

    // **************************** //
    // *     Constant getters     * //
    // **************************** //

    /** @dev Getter to know the count of transactions.
     *  @return countTransactions The count of transactions.
     */
    function getCountTransactions() public view returns (uint countTransactions) {
        return transactions.length;
    }

    /** @dev Get IDs for transactions where the specified address is the receiver and/or the sender.
     *  This function must be used by the UI and not by other smart contracts.
     *  Note that the complexity is O(t), where t is amount of arbitrable transactions.
     *  @param _address The specified address.
     *  @return transactionIDs The transaction IDs.
     */
    function getTransactionIDsByAddress(address _address) public view returns (uint[] memory transactionIDs) {
        uint count = 0;
        for (uint i = 0; i < transactions.length; i++) {
            if (transactions[i]._transaction.sender == _address || transactions[i]._transaction.receiver == _address)
                count++;
        }

        transactionIDs = new uint[](count);

        count = 0;

        for (uint j = 0; j < transactions.length; j++) {
            if (transactions[j]._transaction.sender == _address || transactions[j]._transaction.receiver == _address)
                transactionIDs[count++] = j;
        }
    }
}