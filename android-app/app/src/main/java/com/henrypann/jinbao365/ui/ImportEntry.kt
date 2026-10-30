package com.henrypann.jinbao365.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import com.henrypann.jinbao365.JinbaoApplication
import com.henrypann.jinbao365.media.AndroidImportRequests

/** Legacy single-item entry retained for local import tests. */
@Composable
fun ImportEntry() {
    val app = LocalContext.current.applicationContext as JinbaoApplication
    val imports = app.imports
    val state = imports.state
    val pickPhoto = rememberMomentPhotoPicker(!state.busy, { uris, fromPhotoPicker ->
        if (uris.size > 1) imports.showStatus("这里一次只能添加一张照片，请重新选择。")
        else uris.firstOrNull()?.let { uri ->
            imports.submit { AndroidImportRequests.create(app, uri, fromPhotoPicker) }
        }
    }, imports::showStatus)
    val pickFile = rememberMomentDocumentPicker(!state.busy, { uris ->
        if (uris.size > 1) imports.showStatus("这里一次只能添加一张照片，请重新选择。")
        else uris.firstOrNull()?.let { uri ->
            imports.submit { AndroidImportRequests.create(app, uri, false) }
        }
    }, imports::showStatus)
    Column(modifier = Modifier.fillMaxWidth()) {
        Button(onClick = pickPhoto, enabled = !state.busy, modifier = Modifier.fillMaxWidth()) {
            Text("从相册里选")
        }
        Button(onClick = pickFile, enabled = !state.busy, modifier = Modifier.fillMaxWidth()) {
            Text("从文件里选")
        }
        Text(text = state.archiveSummary, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
        Text(text = state.status, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
    }
}
