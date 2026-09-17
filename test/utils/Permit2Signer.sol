// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IEIP712} from "permit2/src/interfaces/IEIP712.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";
import {PermitHash} from "permit2/src/libraries/PermitHash.sol";

/// @notice Signs Permit2 `PermitTransferFrom` messages with forge's `vm.sign`, for unit and fork tests.
/// @dev The type hashes are Permit2's own (`PermitHash`); the domain separator is read from the Permit2 instance,
///      so the same helper works against the etched Permit2 in unit tests and the canonical one on a fork.
library Permit2Signer {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice The EIP-712 digest `owner` signs so that `spender` may pull `permit.permitted` through `permit2`.
    function digest(address permit2, ISignatureTransfer.PermitTransferFrom memory permit, address spender)
        internal
        view
        returns (bytes32)
    {
        bytes32 tokenPermissions = keccak256(abi.encode(PermitHash._TOKEN_PERMISSIONS_TYPEHASH, permit.permitted));
        bytes32 structHash = keccak256(
            abi.encode(
                PermitHash._PERMIT_TRANSFER_FROM_TYPEHASH, tokenPermissions, spender, permit.nonce, permit.deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", IEIP712(permit2).DOMAIN_SEPARATOR(), structHash));
    }

    /// @notice A 65-byte `r || s || v` signature over `digest(...)` by `privateKey`.
    function sign(
        uint256 privateKey,
        address permit2,
        ISignatureTransfer.PermitTransferFrom memory permit,
        address spender
    ) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = VM.sign(privateKey, digest(permit2, permit, spender));
        return abi.encodePacked(r, s, v);
    }
}
