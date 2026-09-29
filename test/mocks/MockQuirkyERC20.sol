// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice A quote currency with the behaviours the launchpad must survive, each off until switched on: refusing
///         chosen recipients of `transfer` by reverting or by answering `false`, answering `transfer` with no
///         return data, and burning a transfer fee on every transfer or only on transfers to one address.
///         `transferFrom` never refuses, so Permit2 and the PoolManager's test router can still pull. Unit tests only.
contract MockQuirkyERC20 is ERC20 {
    /// @notice How `transfer` treats one recipient.
    enum Refusal {
        None,
        Revert,
        ReturnFalse
    }

    /// @notice `transfer` to `to` is refused by revert.
    error Refused(address to);

    uint8 private immutable DECIMALS;
    mapping(address => Refusal) public refusal;
    bool public noReturnData;
    uint16 public feeBps;
    address public feeOnlyTo;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        DECIMALS = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return DECIMALS;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setRefusal(address to, Refusal mode) external {
        refusal[to] = mode;
    }

    function setNoReturnData(bool on) external {
        noReturnData = on;
    }

    /// @param bps The share of every taxed transfer that is burned.
    /// @param onlyTo Tax only transfers to this address; zero taxes every transfer.
    function setTransferFee(uint16 bps, address onlyTo) external {
        feeBps = bps;
        feeOnlyTo = onlyTo;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        Refusal mode = refusal[to];
        if (mode == Refusal.Revert) revert Refused(to);
        if (mode == Refusal.ReturnFalse) return false;
        _transfer(msg.sender, to, value);
        if (noReturnData) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return true;
    }

    /// @dev The fee is burned from the amount sent: the sender is debited `value`, the recipient credited the rest.
    function _update(address from, address to, uint256 value) internal override {
        bool taxed =
            feeBps != 0 && from != address(0) && to != address(0) && (feeOnlyTo == address(0) || to == feeOnlyTo);
        if (!taxed) {
            super._update(from, to, value);
            return;
        }
        uint256 fee = value * feeBps / 10_000;
        super._update(from, address(0), fee);
        super._update(from, to, value - fee);
    }
}
