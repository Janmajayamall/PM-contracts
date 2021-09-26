pragma solidity ^0.8.0;

import "./IERC20.sol";

interface IStarknetCore {
    /**
      Sends a message to an L2 contract.
    */
    function sendMessageToL2(
        uint256 to_address,
        uint256 selector,
        uint256[] calldata payload
    ) external;

    /**
      Consumes a message that was sent from an L2 contract.
    */
    function consumeMessageFromL2(uint256 fromAddress, uint256[] calldata payload) external;
}

/**
  Demo contract for L1 <-> L2 interaction between an L2 StarkNet contract and this L1 solidity
  contract.
*/
contract L1L2 {
    // The StarkNet core contract.
    IStarknetCore _starknetCore;
    
    // USDC
    IERC20 fakeUSD = IERC20(0x99097Dd486e689d8268aa18FcFF87689b5681F01);

    uint256 private _l2ContractAddress;

    mapping(uint256 => uint256) public userBalances;
    mapping(address => uint256) public starkeys;

    uint256 constant MESSAGE_WITHDRAW = 0;
    // The selector of the "deposit" l1_handler.
    uint256 constant DEPOSIT_SELECTOR =
        352040181584456735608515580760888541466059565068553383579463728554843487745;

    address immutable owner;

    event Register(address indexed user, uint256 indexed starkey);

    modifier onlyOwner() {
        require(msg.sender == owner);
        _;
    }

    /**
      Initializes the contract state.
    */
    constructor(address starknetCore) {
        // core stark net contract address - 0x5e6229F2D4d977d20A50219E521dE6Dd694d45cc
        _starknetCore = IStarknetCore(starknetCore);
        owner = msg.sender;
    }

    function _withdrawL2(
        uint256 l2ContractAddress,
        uint256 user,
        uint256 amount
    ) internal {
        // Construct the withdrawal message's payload.
        uint256[] memory payload = new uint256[](3);
        payload[0] = MESSAGE_WITHDRAW;
        payload[1] = user;
        payload[2] = amount;

        // Consume the message from the StarkNet core contract.
        // This will revert the (Ethereum) transaction if the message does not exist.
        _starknetCore.consumeMessageFromL2(l2ContractAddress, payload);

        // Update the L1 balance.
        userBalances[user] += amount;
    }

    function _depositL2(
        uint256 l2ContractAddress,
        uint256 user,
        uint256 amount
    ) internal {
        require(amount < 2**64, "Invalid amount.");
        require(amount <= userBalances[user], "The user's balance is not large enough.");

        // Update the L1 balance.
        userBalances[user] -= amount;

        // Construct the deposit message's payload.
        uint256[] memory payload = new uint256[](2);
        payload[0] = user;
        payload[1] = amount;

        // Send the message to the StarkNet core contract.
        _starknetCore.sendMessageToL2(l2ContractAddress, DEPOSIT_SELECTOR, payload);
    }

    function depositUSDC(uint256 amount, uint256 user) public {
        uint256 balance0 = fakeUSD.balanceOf(address(this));
        fakeUSD.transferFrom(msg.sender, address(this), amount);
        uint256 balance1 = fakeUSD.balanceOf(address(this));
        require(balance1-balance0 == amount);
        userBalances[user]+=amount;
        _depositL2(_l2ContractAddress, user, amount);
    }

    function withdrawUSDC(uint256 amount, uint256 user) external {
        _withdrawL2(_l2ContractAddress, user, amount);
        fakeUSD.transfer(msg.sender, amount);
        userBalances[user] -= amount;
    }

    function modifyL2Address(uint256 l2ContractAddress) external onlyOwner {
        _l2ContractAddress = l2ContractAddress;
    }
}