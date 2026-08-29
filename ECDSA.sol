// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// OpenZeppelin Contracts (utils/cryptography/ECDSA.sol), reduced to the
// v/r/s recovery path used by BrokexCore.
library ECDSA {
    enum RecoverError {
        NoError,
        InvalidSignature,
        InvalidSignatureLength,
        InvalidSignatureS
    }

    error ECDSAInvalidSignature();
    error ECDSAInvalidSignatureS(bytes32 s);

    function recover(bytes32 hash, uint8 v, bytes32 r, bytes32 s) internal pure returns (address signer) {
        RecoverError error;
        bytes32 errorArgument;
        (signer, error, errorArgument) = tryRecover(hash, v, r, s);
        if (error == RecoverError.InvalidSignatureS) revert ECDSAInvalidSignatureS(errorArgument);
        if (error != RecoverError.NoError) revert ECDSAInvalidSignature();
    }

    function tryRecover(bytes32 hash, uint8 v, bytes32 r, bytes32 s)
        internal
        pure
        returns (address signer, RecoverError error, bytes32 errorArgument)
    {
        if (uint256(s) > 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0) {
            return (address(0), RecoverError.InvalidSignatureS, s);
        }
        signer = ecrecover(hash, v, r, s);
        if (signer == address(0)) return (address(0), RecoverError.InvalidSignature, bytes32(0));
        return (signer, RecoverError.NoError, bytes32(0));
    }
}
