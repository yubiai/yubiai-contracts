// SPDX-License-Identifier: MIT
pragma solidity ~0.7.6;
pragma abicoder v2;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.4-solc-0.7/contracts/token/ERC20/ERC20.sol";
import "./IMultipleArbitrableTransaction.sol";

contract PaymentProcessor {
    IMultipleArbitrableTransaction multipleArbitrableAddress;
    uint256 public DIVISOR = 100;
    uint256 public adminFee;
    address payable public admin; 
    address payable public burnAddress;

    struct TransferInfo {
        uint256 amount;
        address token;
        uint256 tokenETHRate;
        bool ETHPriceGreaterThanToken;
    }

    struct TransactionData {
        address payable sender;
        uint256 timeoutPayment;
        address payable receiver;
        string metaEvidence;
    }

    event MetaEvidence(uint indexed _metaEvidenceID, string _evidence);

    event PaymentDone(
        address payer,
        uint amount,
        uint paymentId,
        uint date
    );

    receive() external payable { }

    constructor(
        address payable adminAddress,
        uint256 _adminFee, 
        address payable _burnAddress,
        address arbitrableAddress
    ) {
        admin = adminAddress;
        adminFee = _adminFee;
        burnAddress = _burnAddress;
        multipleArbitrableAddress = IMultipleArbitrableTransaction(arbitrableAddress);
    }

    function changeAdminFee(uint256 newAdminFee) external {
        require(msg.sender == address(admin), "Unauthorized");
        require(newAdminFee < DIVISOR, "Fee too big");
        adminFee = newAdminFee;
    }

    function managePayment(
        uint paymentId,
        uint256 burnFee,
        TransferInfo memory _transferInfo,
        TransactionData memory _transactionData
    ) public payable returns (uint transactionID) {
        require(burnFee + adminFee < DIVISOR, "Fee too big");
        uint256 burnAmount = _transferInfo.amount / DIVISOR * burnFee;
        uint256 adminAmount = _transferInfo.amount / DIVISOR * adminFee;
        uint256 receiverAmount = _transferInfo.amount - burnAmount - adminAmount;

        if (_transferInfo.tokenETHRate != 0) {
            uint256 baseAmountInETH = _transferInfo.ETHPriceGreaterThanToken
                ? _transferInfo.amount / _transferInfo.tokenETHRate : _transferInfo.amount * _transferInfo.tokenETHRate;
            burnAmount = baseAmountInETH / DIVISOR * burnFee;
            adminAmount = baseAmountInETH / DIVISOR * adminFee;
        }

        /* Calculate fee, token or ETH, based only on ETH wei value */

        uint256 transactionIndex = createTransaction(
            _transactionData,
            _transferInfo.token,
            receiverAmount,
            burnAmount,
            adminAmount
        );

        emit PaymentDone(msg.sender, receiverAmount, paymentId, block.timestamp);
        emit MetaEvidence(transactionIndex, _transactionData.metaEvidence);

        return transactionIndex;
    }

    /*
      Kleros-based methods
    */

    function createTransaction(
        TransactionData memory _transactionData,
        address _tokenAddress,
        uint _amount,
        uint256 burnAmount,
        uint256 adminAmount
    ) public payable returns (uint256 transactionID) {
        return multipleArbitrableAddress.createTransaction(
            _transactionData.timeoutPayment,
            _transactionData.sender,
            _transactionData.receiver,
            _transactionData.metaEvidence,
            _tokenAddress,
            _amount,
            admin,
            adminAmount,
            burnAddress,
            burnAmount
        );
    }
}
