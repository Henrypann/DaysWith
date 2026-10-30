package com.henrypann.jinbao365.backup

import com.henrypann.jinbao365.data.ParentIdentity
import com.henrypann.jinbao365.storage.SavedConnection
import com.henrypann.jinbao365.storage.StorageConfiguration

/** forParent is the identity root (read side); forWriter is this device's own chain. */
object V1Destination {
    fun forParent(root: StorageConfiguration, parent: ParentIdentity): StorageConfiguration =
        root.copy(prefix = parent.prefix)

    /** This installation's own chain; no two devices ever share a writable chain. */
    fun forWriter(root: StorageConfiguration, parent: ParentIdentity, deviceId: String, test: Boolean): StorageConfiguration =
        root.copy(prefix = V1Layout.chainPrefix(parent, deviceId, test))

    fun rootOf(destination: StorageConfiguration, savedRoot: StorageConfiguration?, parent: ParentIdentity?,
               deviceId: String, test: Boolean): StorageConfiguration? =
        savedRoot?.takeIf { parent != null && forWriter(it, parent, deviceId, test) == destination }

    /** No parent selection means no writable destination, even with valid cloud credentials. */
    fun mapConnection(saved: SavedConnection, parent: ParentIdentity?, deviceId: String, test: Boolean): SavedConnection =
        if (parent == null) SavedConnection.Missing else when (saved) {
            is SavedConnection.Verified -> SavedConnection.Verified(forWriter(saved.configuration, parent, deviceId, test))
            is SavedConnection.Configured -> SavedConnection.Configured(forWriter(saved.configuration, parent, deviceId, test))
            else -> saved
        }
}
