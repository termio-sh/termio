package sh.termio.android

import android.util.Log
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.mlkit.vision.MlKitAnalyzer
import androidx.camera.view.CameraController
import androidx.camera.view.LifecycleCameraController
import androidx.camera.view.PreviewView
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.common.Barcode

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun QrScanner(onDismiss: () -> Unit, onScan: (String) -> Unit) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val scan by rememberUpdatedState(onScan)
    var error by remember { mutableStateOf("") }
    val preview = remember(context) {
        PreviewView(context).apply {
            implementationMode = PreviewView.ImplementationMode.COMPATIBLE
        }
    }
    DisposableEffect(preview, lifecycleOwner) {
        val executor = ContextCompat.getMainExecutor(context)
        val decoder = BarcodeScanning.getClient(BarcodeScannerOptions.Builder()
            .setBarcodeFormats(Barcode.FORMAT_QR_CODE).build())
        val controller = LifecycleCameraController(context)
        var active = true
        var handled = false
        controller.cameraSelector = CameraSelector.DEFAULT_BACK_CAMERA
        controller.setEnabledUseCases(CameraController.IMAGE_ANALYSIS)
        controller.setImageAnalysisAnalyzer(executor, MlKitAnalyzer(listOf(decoder),
            ImageAnalysis.COORDINATE_SYSTEM_ORIGINAL, executor) { result ->
            if (active && !handled) {
                val failure = result.getThrowable(decoder)
                if (failure != null) {
                    Log.w("QrScanner", "QR decoding failed: ${failure.javaClass.simpleName}")
                    error = "Couldn’t read the QR code. Try again."
                } else {
                    val code = result.getValue(decoder)?.firstOrNull { !it.rawValue.isNullOrEmpty() }?.rawValue
                    if (code != null) {
                        val address = try {
                            CompanionProtocol.pairingAddress(code).url
                        } catch (failure: IllegalArgumentException) {
                            error = failure.message.orEmpty()
                            null
                        }
                        if (address != null) {
                            handled = true
                            scan(address)
                        }
                    }
                }
            }
        })
        try {
            preview.controller = controller
            controller.bindToLifecycle(lifecycleOwner)
            controller.initializationFuture.addListener({
                if (active) try {
                    controller.initializationFuture.get()
                } catch (failure: Exception) {
                    Log.w("QrScanner", "Camera unavailable: ${failure.javaClass.simpleName}")
                    error = "Couldn’t open the camera. Close other camera apps and try again."
                }
            }, executor)
        } catch (failure: Exception) {
            Log.w("QrScanner", "Camera unavailable: ${failure.javaClass.simpleName}")
            error = "Couldn’t open the camera. Close other camera apps and try again."
        }
        onDispose {
            active = false
            controller.clearImageAnalysisAnalyzer()
            controller.unbind()
            preview.controller = null
            decoder.close()
        }
    }
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Scaffold(modifier = Modifier.fillMaxSize(), topBar = {
            TopAppBar(title = { Text("Scan QR Code") }, actions = {
                TextButton(onClick = onDismiss) { Text("Cancel") }
            })
        }, bottomBar = {
            Text(error.ifEmpty { "Point your camera at the QR code in Termio’s Mobile settings." },
                modifier = Modifier.padding(20.dp),
                color = if (error.isEmpty()) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.error)
        }) { padding ->
            AndroidView(factory = { preview }, modifier = Modifier.fillMaxSize().padding(padding))
        }
    }
}
