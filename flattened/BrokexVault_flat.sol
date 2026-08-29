// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// IERC20.sol

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

// BrokexVault.sol

interface IBrokexCore {
    function owner() external view returns (address);
    function USDC() external view returns (IERC20);
    function vault() external view returns (address);
    function lockedCapital() external view returns (uint256);
    function securityMode() external view returns (uint8);
}

contract BrokexVault {
    uint8 internal constant MODE_PAUSED = 2;
    uint8 internal constant MODE_RECOVERY = 3;

    address public immutable bootstrapOwner;
    address public primaryCore;

    error Unauthorized();
    error InvalidInput();
    error InvalidState();
    error TransferFailed();

    modifier onlyOwner() {
        if (msg.sender != owner()) revert Unauthorized();
        _;
    }

    modifier onlyCore() {
        if (msg.sender != primaryCore) revert Unauthorized();
        _;
    }

    constructor() {
        bootstrapOwner = msg.sender;
    }

    function owner() public view returns (address) {
        address core = primaryCore;
        return core == address(0) ? bootstrapOwner : IBrokexCore(core).owner();
    }

    function setPrimaryCore(address core) external onlyOwner {
        if (primaryCore != address(0)) revert InvalidState();
        if (core == address(0) || core.code.length == 0) revert InvalidInput();
        primaryCore = core;
        if (IBrokexCore(core).vault() != address(this)) revert InvalidInput();
    }

    function deposit(uint256 amount) external onlyOwner {
        if (primaryCore != address(0) && IBrokexCore(primaryCore).securityMode() == MODE_PAUSED) revert InvalidState();
        if (amount == 0) revert InvalidInput();
        if (!_usdc().transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
    }

    function withdraw(uint256 amount) external onlyOwner {
        if (amount == 0) revert InvalidInput();

        uint256 balance = _usdc().balanceOf(address(this));
        uint8 mode = primaryCore == address(0) ? 0 : IBrokexCore(primaryCore).securityMode();
        if (mode == MODE_PAUSED) revert InvalidState();

        uint256 locked =
            primaryCore == address(0) || mode == MODE_RECOVERY ? 0 : IBrokexCore(primaryCore).lockedCapital();
        uint256 freeCapital = balance > locked ? balance - locked : 0;

        if (amount > freeCapital) revert InvalidState();
        if (!_usdc().transfer(msg.sender, amount)) revert TransferFailed();
    }

    function payTrader(address trader, uint256 amount) external onlyCore {
        if (IBrokexCore(primaryCore).securityMode() >= MODE_PAUSED) revert InvalidState();
        if (trader == address(0)) revert InvalidInput();
        if (amount == 0) return;
        if (!_usdc().transfer(trader, amount)) revert TransferFailed();
    }

    function _usdc() internal view returns (IERC20) {
        return IBrokexCore(primaryCore).USDC();
    }
}
