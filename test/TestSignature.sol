// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "../ECDSA.sol";

contract TestSignature {
    function recover(
        address coreAddress,
        uint256 chainId,
        uint256 maxOILong,
        uint256 maxOIShort,
        uint256 timestamp,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external pure returns (address signer, bytes32 digest) {
        digest = keccak256(abi.encodePacked(coreAddress, chainId, maxOILong, maxOIShort, timestamp));
        signer = ECDSA.recover(digest, v, r, s);
    }
}
