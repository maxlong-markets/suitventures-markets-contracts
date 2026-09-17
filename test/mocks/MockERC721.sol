// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @notice Plain ERC721 with free minting, standing in for the Suits NFT. Unit tests only.
contract MockERC721 is ERC721 {
    constructor() ERC721("Mock Suits", "SUITS") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }
}
