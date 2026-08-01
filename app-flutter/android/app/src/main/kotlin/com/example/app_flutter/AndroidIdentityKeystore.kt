package com.example.app_flutter

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.io.File
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Stores the 32-byte Ed25519 identity seed encrypted at rest.
 *
 * Android Keystore keys are not exportable, and the Dart daemon needs the raw
 * seed, so the seed itself cannot live inside the Keystore. Instead a
 * Keystore-held AES-256-GCM key wraps the seed, and only the ciphertext
 * touches disk. Existing plaintext `identity.key` files are migrated in place
 * so devices keep their identity.
 */
object AndroidIdentityKeystore {
    private const val keystoreAlias = "rift.identity.wrap"
    private const val wrappedFileName = "identity.key.enc"
    private const val seedLength = 32
    private const val gcmTagBits = 128
    private const val gcmIvLength = 12

    fun loadOrCreate(context: Context, legacyPath: String?): ByteArray {
        val wrappedFile = File(context.filesDir, wrappedFileName)
        if (wrappedFile.exists()) {
            val seed = unwrap(wrappedFile.readBytes())
            require(seed.size == seedLength) { "Corrupted identity seed: expected $seedLength bytes." }
            return seed
        }

        val legacyFile = legacyPath?.let(::File)
        val seed = if (legacyFile != null && legacyFile.exists()) {
            val bytes = legacyFile.readBytes()
            require(bytes.size == seedLength) { "Corrupted legacy identity key: expected $seedLength bytes." }
            bytes
        } else {
            ByteArray(seedLength).also { SecureRandom().nextBytes(it) }
        }

        // Atomic write: never leave a partial ciphertext behind.
        val tempFile = File(wrappedFile.parentFile, "$wrappedFileName.tmp")
        tempFile.writeBytes(wrap(seed))
        if (!tempFile.renameTo(wrappedFile)) {
            tempFile.delete()
            throw IllegalStateException("Failed to persist wrapped identity seed.")
        }
        // Remove the plaintext seed only after the wrapped copy is durable.
        legacyFile?.delete()
        return seed
    }

    private fun wrappingKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getKey(keystoreAlias, null) as? SecretKey)?.let { return it }

        val generator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES,
            "AndroidKeyStore",
        )
        generator.init(
            KeyGenParameterSpec.Builder(
                keystoreAlias,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return generator.generateKey()
    }

    private fun wrap(seed: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, wrappingKey())
        val ciphertext = cipher.doFinal(seed)
        require(cipher.iv.size == gcmIvLength) { "Unexpected GCM IV length ${cipher.iv.size}." }
        return cipher.iv + ciphertext
    }

    private fun unwrap(blob: ByteArray): ByteArray {
        require(blob.size > gcmIvLength) { "Corrupted wrapped identity seed." }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.DECRYPT_MODE,
            wrappingKey(),
            GCMParameterSpec(gcmTagBits, blob.copyOfRange(0, gcmIvLength)),
        )
        return cipher.doFinal(blob.copyOfRange(gcmIvLength, blob.size))
    }
}
