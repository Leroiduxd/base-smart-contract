// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "../ECDSA.sol";

contract CheckAllSchemes {
    function checkAll(
        address coreAddress,
        uint256 chainId,
        uint256 maxOILong,
        uint256 maxOIShort,
        uint256 timestamp,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external pure returns (
        address standard,
        address ethSigned,
        address withoutChainId,
        address ethSignedWithoutChainId,
        address abiEncode,
        address ethSignedAbiEncode
    ) {
        // 1. standard abi.encodePacked
        bytes32 d1 = keccak256(abi.encodePacked(coreAddress, chainId, maxOILong, maxOIShort, timestamp));
        standard = ECDSA.recover(d1, v, r, s);

        // 2. eth signed standard
        bytes32 d2 = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", d1));
        ethSigned = ECDSA.recover(d2, v, r, s);

        // 3. without chainId
        bytes32 d3 = keccak256(abi.encodePacked(coreAddress, maxOILong, maxOIShort, timestamp));
        withoutChainId = ECDSA.recover(d3, v, r, s);

        // 4. eth signed without chainId
        bytes32 d4 = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", d3));
        ethSignedWithoutChainId = ECDSA.recover(d4, v, r, s);

        // 5. abi.encode (padded 32 bytes)
        bytes32 d5 = keccak256(abi.encode(coreAddress, chainId, maxOILong, maxOIShort, timestamp));
        abiEncode = ECDSA.recover(d5, v, r, s);

        // 6. eth signed abi.encode
        bytes32 d6 = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", d5));
        ethSignedAbiEncode = ECDSA.recover(d6, v, r, s);
    }
}
