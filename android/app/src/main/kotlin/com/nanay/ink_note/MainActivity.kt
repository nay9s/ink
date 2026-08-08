package com.nanay.ink_note

import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.RectF
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.os.ext.SdkExtensions
import android.provider.OpenableColumns
import android.util.SparseArray
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.TextView
import androidx.pdf.ExperimentalPdfApi
import androidx.pdf.PdfDocument
import androidx.pdf.PdfWriteHandle
import androidx.pdf.ink.EditablePdfViewerFragment
import androidx.pdf.view.PdfView
import androidx.lifecycle.lifecycleScope
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.io.File
import java.io.FileOutputStream
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MainActivity : FlutterFragmentActivity() {
    private var notenFileChannel: MethodChannel? = null
    private val deliveredNotenPaths = mutableSetOf<String>()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.platformViewsController.registry.registerViewFactory(
            "ink_note/native_pdf_view",
            NativePdfViewFactory(this, flutterEngine),
        )
        notenFileChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            NOTEN_CHANNEL,
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "takePendingPath" -> result.success(takePendingNotenPath())
                    else -> result.notImplemented()
                }
            }
        }
        captureNotenIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        captureNotenIntent(intent)
    }

    override fun onDestroy() {
        notenFileChannel?.setMethodCallHandler(null)
        notenFileChannel = null
        super.onDestroy()
    }

    private fun captureNotenIntent(sourceIntent: Intent?): Boolean {
        if (sourceIntent?.action != Intent.ACTION_VIEW) return false
        if (sourceIntent.getBooleanExtra(NOTEN_INTENT_CONSUMED, false)) return false
        val uri = sourceIntent.data ?: return false
        if (!isNotenUri(uri)) return false

        return try {
            val directory = notenInboxDirectory().apply { mkdirs() }
            val destination = File(directory, "${UUID.randomUUID()}.noten")
            val input = contentResolver.openInputStream(uri) ?: return false
            input.use { stream ->
                FileOutputStream(destination).use { output ->
                    stream.copyTo(output)
                }
            }
            sourceIntent.putExtra(NOTEN_INTENT_CONSUMED, true)
            notenFileChannel?.invokeMethod("fileAvailable", null)
            true
        } catch (_: Throwable) {
            false
        }
    }

    private fun isNotenUri(uri: Uri): Boolean {
        if (contentResolver.getType(uri)?.equals(NOTEN_MIME, ignoreCase = true) == true) {
            return true
        }
        val displayName = try {
            contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME),
                null,
                null,
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getString(0) else null
            }
        } catch (_: Throwable) {
            null
        }
        return (displayName ?: uri.lastPathSegment.orEmpty())
            .endsWith(".noten", ignoreCase = true)
    }

    private fun notenInboxDirectory(): File = File(cacheDir, "noten_inbox")

    private fun takePendingNotenPath(): String? {
        val path = notenInboxDirectory()
            .listFiles { file ->
                file.isFile &&
                    file.extension.equals("noten", ignoreCase = true) &&
                    !deliveredNotenPaths.contains(file.absolutePath)
            }
            ?.minByOrNull(File::lastModified)
            ?.absolutePath
            ?: return null
        deliveredNotenPaths.add(path)
        return path
    }

    private companion object {
        const val NOTEN_CHANNEL = "ink_note/noten_files"
        const val NOTEN_MIME = "application/x-noten"
        const val NOTEN_INTENT_CONSUMED = "ink_note.noten_intent_consumed"
    }
}

private fun supportsEditablePdf(): Boolean {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return false
    return SdkExtensions.getExtensionVersion(Build.VERSION_CODES.S) >= 18
}

private class NativePdfViewFactory(
    private val activity: MainActivity,
    private val flutterEngine: FlutterEngine,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        @Suppress("UNCHECKED_CAST")
        val values = args as? Map<String, Any?> ?: emptyMap()
        val path = values["path"] as? String ?: ""
        val initialPage = (values["initialPage"] as? Number)?.toInt() ?: 0
        if (!supportsEditablePdf()) {
            return UnsupportedNativePdfPlatformView(
                context = context,
                flutterEngine = flutterEngine,
                viewId = viewId,
            )
        }
        return NativePdfPlatformView(
            activity = activity,
            flutterEngine = flutterEngine,
            viewId = viewId,
            path = path,
            initialPage = initialPage,
        )
    }
}

private class UnsupportedNativePdfPlatformView(
    context: Context,
    flutterEngine: FlutterEngine,
    viewId: Int,
) : PlatformView {
    private val messageView = TextView(context).apply {
        setBackgroundColor(Color.WHITE)
        setTextColor(Color.DKGRAY)
        gravity = Gravity.CENTER
        textSize = 16f
        setPadding(48, 48, 48, 48)
        text = "Native editable PDF requires Android 12 or newer with SDK Extension 18."
    }
    private val channel = MethodChannel(
        flutterEngine.dartExecutor.binaryMessenger,
        "ink_note/native_pdf_view_$viewId",
    )

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "goToPage", "setTool", "undo", "redo", "save" -> result.success(null)
                else -> result.notImplemented()
            }
            if (call.method == "setTool") {
                channel.invokeMethod(
                    "historyChanged",
                    mapOf(
                        "canUndo" to false,
                        "canRedo" to false,
                        "supportsAppHistory" to false,
                    ),
                )
            }
        }
    }

    override fun getView(): View = messageView

    override fun dispose() {
        channel.setMethodCallHandler(null)
    }
}

@OptIn(ExperimentalPdfApi::class)
private class InkPdfViewerFragment : EditablePdfViewerFragment() {
    var onPdfViewReady: ((PdfView) -> Unit)? = null
    var outputFile: File? = null

    private val pendingSaveCallbacks = mutableListOf<(Result<Unit>) -> Unit>()

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)
        view.post { isEditModeEnabled = true }
    }

    override fun onLoadDocumentSuccess(document: PdfDocument) {
        super.onLoadDocumentSuccess(document)
        isEditModeEnabled = true
        isToolboxVisible = true
    }

    override fun onPdfViewCreated(pdfView: PdfView) {
        super.onPdfViewCreated(pdfView)
        onPdfViewReady?.invoke(pdfView)
    }

    fun saveEdits(callback: (Result<Unit>) -> Unit) {
        if (!isAdded) {
            callback(Result.failure(IllegalStateException("PDF editor is not attached.")))
            return
        }
        if (!hasUnsavedChanges) {
            callback(Result.success(Unit))
            return
        }
        pendingSaveCallbacks.add(callback)
        if (isApplyEditsInProgress) return
        try {
            applyDraftEdits()
        } catch (error: Throwable) {
            finishSave(Result.failure(error))
        }
    }

    override fun onApplyEditsSuccess(handle: PdfWriteHandle) {
        val destination = outputFile
        if (destination == null) {
            handle.close()
            finishSave(Result.failure(IllegalStateException("PDF output file is missing.")))
            return
        }

        lifecycleScope.launch {
            val outcome = try {
                withContext(Dispatchers.IO) {
                    handle.use { writer ->
                        val parent = destination.parentFile
                            ?: throw IllegalStateException(
                                "PDF output directory is missing.",
                            )
                        parent.mkdirs()
                        val temporary = File(
                            parent,
                            ".${destination.name}.${UUID.randomUUID()}.tmp",
                        )
                        try {
                            ParcelFileDescriptor.open(
                                temporary,
                                ParcelFileDescriptor.MODE_CREATE or
                                    ParcelFileDescriptor.MODE_TRUNCATE or
                                    ParcelFileDescriptor.MODE_READ_WRITE,
                            ).use { fileDescriptor ->
                                writer.writeTo(fileDescriptor)
                            }

                            if (destination.exists() && !destination.delete()) {
                                throw IllegalStateException(
                                    "Could not replace the original PDF.",
                                )
                            }
                            if (!temporary.renameTo(destination)) {
                                temporary.copyTo(destination, overwrite = true)
                                temporary.delete()
                            }
                        } catch (error: Throwable) {
                            temporary.delete()
                            throw error
                        }
                    }
                }
                Result.success(Unit)
            } catch (error: Throwable) {
                Result.failure(error)
            }

            if (outcome.isSuccess) {
                // The AndroidX PDF API requires the host to exit edit mode
                // after a successful write. Re-enter immediately so the user
                // can continue.
                isEditModeEnabled = false
                view?.post {
                    isEditModeEnabled = true
                    isToolboxVisible = true
                }
            } else {
                isEditModeEnabled = true
            }
            finishSave(outcome)
        }
    }

    override fun onApplyEditsFailed(error: Throwable) {
        isEditModeEnabled = true
        finishSave(Result.failure(error))
    }

    private fun finishSave(result: Result<Unit>) {
        val callbacks = pendingSaveCallbacks.toList()
        pendingSaveCallbacks.clear()
        callbacks.forEach { it(result) }
    }
}

@OptIn(ExperimentalPdfApi::class)
private class NativePdfPlatformView(
    private val activity: MainActivity,
    flutterEngine: FlutterEngine,
    viewId: Int,
    path: String,
    initialPage: Int,
) : PlatformView {
    private val container = FrameLayout(activity).apply {
        id = View.generateViewId()
        setBackgroundColor(Color.WHITE)
    }
    private val fragment = InkPdfViewerFragment().apply {
        outputFile = path.takeIf { it.isNotBlank() }?.let(::File)
    }
    private val fragmentTag = "native_pdf_$viewId"
    private val channel = MethodChannel(
        flutterEngine.dartExecutor.binaryMessenger,
        "ink_note/native_pdf_view_$viewId",
    )
    private var pdfView: PdfView? = null
    private var pendingPage: Int? = initialPage

    init {
        fragment.onPdfViewReady = { view ->
            pdfView = view
            view.addOnViewportChangedListener(
                object : PdfView.OnViewportChangedListener {
                    override fun onViewportChanged(
                        firstVisiblePage: Int,
                        visiblePagesCount: Int,
                        pageLocations: SparseArray<RectF>,
                        zoomLevel: Float,
                    ) {
                        channel.invokeMethod(
                            "pageChanged",
                            mapOf("page" to firstVisiblePage),
                        )
                    }
                },
            )
            val target = pendingPage
            if (target != null) {
                view.post {
                    view.scrollToPage(target.coerceAtLeast(0))
                    pendingPage = null
                }
            }
        }

        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "goToPage" -> {
                    @Suppress("UNCHECKED_CAST")
                    val values = call.arguments as? Map<String, Any?>
                    val page = (values?.get("page") as? Number)?.toInt() ?: 0
                    val view = pdfView
                    if (view == null) {
                        pendingPage = page
                    } else {
                        view.post { view.scrollToPage(page.coerceAtLeast(0)) }
                    }
                    result.success(null)
                }
                "setTool" -> {
                    // AndroidX currently exposes its own complete PDF toolbox,
                    // but not a public API for selecting a pen from Flutter.
                    fragment.isEditModeEnabled = true
                    if (fragment.documentUri != null) {
                        fragment.isToolboxVisible = true
                    }
                    channel.invokeMethod(
                        "historyChanged",
                        mapOf(
                            "canUndo" to false,
                            "canRedo" to false,
                            "supportsAppHistory" to false,
                        ),
                    )
                    result.success(null)
                }
                "save" -> {
                    fragment.saveEdits { outcome ->
                        activity.runOnUiThread {
                            outcome.fold(
                                onSuccess = { result.success(null) },
                                onFailure = { error ->
                                    result.error(
                                        "native_pdf_save_failed",
                                        error.message ?: "Could not save PDF annotations.",
                                        null,
                                    )
                                },
                            )
                        }
                    }
                }
                "undo", "redo" -> {
                    // Undo and Redo remain available in AndroidX's native
                    // toolbox. There is no public alpha19 command API for them.
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        activity.supportFragmentManager
            .beginTransaction()
            .replace(container.id, fragment, fragmentTag)
            .commitNow()
        if (path.isNotBlank()) {
            fragment.documentUri = Uri.fromFile(File(path))
            fragment.view?.post { fragment.isEditModeEnabled = true }
        }
    }

    override fun getView(): View = container

    override fun dispose() {
        channel.setMethodCallHandler(null)
        fragment.onPdfViewReady = null
        pdfView = null
        val current = activity.supportFragmentManager.findFragmentByTag(fragmentTag)
        if (current != null && !activity.supportFragmentManager.isStateSaved) {
            activity.supportFragmentManager
                .beginTransaction()
                .remove(current)
                .commitNowAllowingStateLoss()
        }
    }
}
