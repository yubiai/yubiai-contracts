// SPDX-License-Identifier: MIT
pragma solidity ~0.7.6;
pragma abicoder v2;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.4-solc-0.7/contracts/token/ERC20/ERC20.sol";
import "./deps/IUniswapV2Router.sol";
import "./IMultipleArbitrableTransaction.sol";


contract PaymentProcessor {
    IMultipleArbitrableTransaction multipleArbitrableAddress;
    uint256 public DIVISOR = 100;
    uint256 public adminFee;
    address payable public admin; 
    address payable public burnAddress;

    address private UNISWAP_V2_ROUTER;
    address private WETH;

    struct TransferInfo {
        address token;
        bool isToken;
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
        address arbitrableAddress,
        address uniswapAddress,
        address wETHAddress
    ) {
        admin = adminAddress;
        adminFee = _adminFee;
        burnAddress = _burnAddress;
        multipleArbitrableAddress = IMultipleArbitrableTransaction(arbitrableAddress);
        UNISWAP_V2_ROUTER = uniswapAddress;
        WETH = wETHAddress;
    }

    /*
        Replace properties defined in SC
    */
    function getAdminFee() external view returns (uint fee) {
        return adminFee;
    }

    function changeArbitrableAddress(address _arbitrableAddress) external {
        require(msg.sender == address(admin), "Unauthorized");
        multipleArbitrableAddress = IMultipleArbitrableTransaction(_arbitrableAddress);
    }

    function changeBurnAddress(address payable _burnAddress) external {
        require(msg.sender == address(admin), "Unauthorized");
        burnAddress = _burnAddress;
    }

    function changeAdminFee(uint256 newAdminFee) external {
        require(msg.sender == address(admin), "Unauthorized");
        require(newAdminFee < DIVISOR, "Fee too big");
        adminFee = newAdminFee;
    }

    /*
        Auxiliar function to get ETH from tokens on token-based transaction, and then use them for fees
    */
    function getETHFromTokens(
        address token,
        uint256 amount,
        uint256 deadline
    ) private returns (uint256) {
        if (amount > 0) {
            address[] memory path = new address[](2);
            path[0] = address(token);
            path[1] = address(WETH);

            IERC20 iToken = IERC20(token);
            require(
                iToken.transferFrom(msg.sender, address(this), amount),
                "Sender does not have enough approved funds."
            );
            iToken.approve(UNISWAP_V2_ROUTER, amount * 10);

            uint256[] memory amounts = IUniswapV2Router(UNISWAP_V2_ROUTER).swapExactTokensForETH(
                amount, 1, path, address(this), deadline);

            return amounts[0];
        } 
        return 0;
    }


    /*
        Entry points to manage payment and create transaction used in Yubiai.
        manageETHPayment, manageTokenPayment
    */
    function manageETHPayment(
        uint paymentId,
        uint256 burnFee,
        TransactionData memory _transactionData
    ) public payable returns (uint transactionID) {
        require(burnFee + adminFee < DIVISOR, "Fee too big");
        uint256 burnAmount = msg.value / DIVISOR * burnFee;
        uint256 adminAmount = msg.value / DIVISOR * adminFee;
        uint256 receiverAmount = msg.value - burnAmount - adminAmount;

        uint256 transactionIndex = createTransaction(
            _transactionData,
            address(0),
            receiverAmount,
            burnAmount,
            adminAmount
        );

        emit PaymentDone(msg.sender, receiverAmount, paymentId, block.timestamp);
        emit MetaEvidence(transactionIndex, _transactionData.metaEvidence);

        return transactionIndex;
    }

    function manageTokenPayment(
        uint256 tokenAmount,
        uint paymentId,
        uint256 burnFee,
        TransferInfo memory _transferInfo,
        TransactionData memory _transactionData
    ) public returns (uint transactionID) {
        require(burnFee + adminFee < DIVISOR, "Fee too big");
        uint256 constDeadline = block.timestamp + 1000000;
        uint256 burnAmount = getETHFromTokens(_transferInfo.token, tokenAmount / DIVISOR * burnFee, constDeadline);
        uint256 adminAmount = getETHFromTokens(_transferInfo.token, tokenAmount / DIVISOR * adminFee, constDeadline);
        uint256 receiverAmount = tokenAmount - burnAmount - adminAmount;

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
        if (_tokenAddress != address(0)) {
            IERC20 token = IERC20(_tokenAddress);
            // Transfers token from sender wallet to contract. Permit before transfer
            require(
                token.transferFrom(msg.sender, address(this), _amount),
                "Sender does not have enough approved funds."
            );
            token.approve(address(multipleArbitrableAddress), _amount);
            return multipleArbitrableAddress.createTokenTransaction{value: adminAmount + burnAmount}(
                _transactionData.timeoutPayment,
                _transactionData.sender,
                _transactionData.receiver,
                _transactionData.metaEvidence,
                _amount,
                _tokenAddress,
                admin,
                adminAmount,
                burnAddress,
                burnAmount
            );
        }
        return multipleArbitrableAddress.createETHTransaction{value: _amount + burnAmount + adminAmount}(
            _transactionData.timeoutPayment,
            _transactionData.sender,
            _transactionData.receiver,
            _transactionData.metaEvidence,
            _amount,
            admin,
            adminAmount,
            burnAddress,
            burnAmount
        );
    }
}
