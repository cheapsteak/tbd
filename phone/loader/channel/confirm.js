// The 6-digit confirmation code both screens show after a pairing handshake.

const HANDSHAKE_HASH_BYTES = 32;

/**
 * The first 4 bytes of the handshake hash, read as a big-endian UInt32,
 * modulo 1,000,000, zero-padded to 6 digits with no space.
 * @param {Uint8Array} handshakeHash 32 bytes
 * @returns {Promise<string>}
 * @throws {RangeError} unless the hash is 32 bytes
 */
export async function confirmationCode(handshakeHash) {
  if (handshakeHash.length !== HANDSHAKE_HASH_BYTES) {
    throw new RangeError(`handshake hash must be ${HANDSHAKE_HASH_BYTES} bytes, got ${handshakeHash.length}`);
  }
  // byteOffset matters: the hash may be a view into a larger buffer.
  const leading = new DataView(handshakeHash.buffer, handshakeHash.byteOffset, 4).getUint32(0, false);
  return String(leading % 1000000).padStart(6, '0');
}
