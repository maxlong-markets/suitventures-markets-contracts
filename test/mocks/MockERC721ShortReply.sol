// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice A contract with code whose `balanceOf` answers with 8 bytes instead of a 32-byte word. It stands in
///         for a wrong Suits NFT address that has code but is not an ERC721: a high-level `balanceOf` call to it
///         would revert in the caller while decoding the reply, outside the reach of try/catch. Unit tests only.
contract MockERC721ShortReply {
    /// @dev Returns the 8 low bytes of the word 1, so the reply is non-zero but not a word.
    function balanceOf(address) external pure returns (uint256) {
        assembly ("memory-safe") {
            mstore(0x00, 1)
            return(0x18, 0x08)
        }
    }
}
