package com.henrypann.jinbao365.viewing

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import com.henrypann.jinbao365.backup.BackupCancellation
import com.henrypann.jinbao365.backup.CosObjectClient
import com.henrypann.jinbao365.backup.V1Destination
import com.henrypann.jinbao365.data.ParentIdentity
import com.henrypann.jinbao365.storage.SavedConnection
import com.henrypann.jinbao365.storage.StorageConnectionStore
import java.io.File
import java.io.OutputStream

internal object AndroidOriginalNetwork {
    fun current(context: Context): OriginalNetwork {
        val manager = context.getSystemService(ConnectivityManager::class.java) ?: return OriginalNetwork.Offline
        val capabilities = manager.getNetworkCapabilities(manager.activeNetwork) ?: return OriginalNetwork.Offline
        val online = capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
        if (!online) return OriginalNetwork.Offline
        val unmetered = capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
        return if (unmetered) OriginalNetwork.Unmetered else OriginalNetwork.Metered
    }
}

/** Opens an authenticated read of the other parent's folder. URLs stay inside the COS client. */
internal class DevicePartnerOriginals(context: Context, private val mediaRoot: File) {
    private val appContext = context.applicationContext
    val preference = CellularOriginalPreference(File(appContext.filesDir, "prefs/cellular-original-preview"))

    fun downloader(): PartnerOriginalDownloader = PartnerOriginalDownloader(mediaRoot, { AndroidOriginalNetwork.current(appContext) }, ::open)

    private fun open(partner: ParentIdentity, cancellation: BackupCancellation): OriginalObjectSource? {
        val store = StorageConnectionStore(appContext)
        val saved = store.load() as? SavedConnection.Verified ?: return null
        val credentials = store.credentialsForVerified(saved.configuration) ?: return null
        val client = CosObjectClient(V1Destination.forParent(saved.configuration, partner), credentials, cancellation)
        return object : OriginalObjectSource {
            override fun head(key: String) = client.head(key)
            override fun download(key: String, output: OutputStream) = client.download(key, output)
            override fun toString() = "OriginalObjectSource(redacted)"
        }
    }
}
