package sh.termio.android

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import android.view.KeyEvent
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.sagernet.libghostty.compose.GhosttyDialogs
import io.github.sagernet.libghostty.compose.GhosttyExtraKeysBar
import io.github.sagernet.libghostty.compose.GhosttyTerminal
import io.github.sagernet.libghostty.compose.rememberGhosttyTerminalState

class MainActivity : ComponentActivity() {
    private val client: CompanionClient by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme(colorScheme = darkColorScheme(
                primary = Color(0xff8eb5ff),
                background = Color(0xff15171c),
                surface = Color(0xff15171c),
            )) {
                TermioApp(client)
            }
        }
    }

    override fun onStart() {
        super.onStart()
        client.setForeground(true)
    }

    override fun onStop() {
        client.setForeground(false)
        super.onStop()
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TermioApp(client: CompanionClient) {
    val state by client.state.collectAsStateWithLifecycle()
    val selected = state.selectedConnection
    val inTerminal = selected?.session != null
    BackHandler(enabled = inTerminal || state.showingPairing) {
        if (inTerminal) client.leaveSession() else client.cancelPairing()
    }
    Scaffold(
        modifier = Modifier.imePadding(),
        topBar = {
            TopAppBar(
                title = {
                    Text(selected?.session?.title ?: "Termio",
                        maxLines = 1, overflow = TextOverflow.Ellipsis)
                },
                navigationIcon = {
                    if (inTerminal) TextButton(onClick = client::leaveSession) { Text("Back") }
                },
                actions = {
                    if (!inTerminal && state.machines.isNotEmpty() && !state.showingPairing) {
                        TextButton(onClick = client::beginPairing) { Text("Add Mac") }
                    }
                },
            )
        },
    ) { padding ->
        val modifier = Modifier.fillMaxSize().padding(padding)
        if (inTerminal && selected != null) key(state.selectedMachineID, selected.session?.id) {
            TerminalPage(selected, modifier)
        } else SessionList(state, client, modifier)
    }
}

@Composable
private fun PairPage(state: HomeState, client: CompanionClient, modifier: Modifier) {
    var scanning by rememberSaveable { mutableStateOf(false) }
    var cameraDenied by rememberSaveable { mutableStateOf(false) }
    val context = LocalContext.current
    val focusManager = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current
    val cameraPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        cameraDenied = !granted
        scanning = granted
    }
    if (scanning) QrScanner(onDismiss = { scanning = false }, onScan = { scannedAddress ->
        scanning = false
        client.connect(scannedAddress)
    })
    Column(modifier.padding(horizontal = 4.dp, vertical = 20.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Image(painterResource(R.drawable.termio_icon), contentDescription = null,
            modifier = Modifier.size(64.dp))
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text("Connect a Mac", style = MaterialTheme.typography.headlineSmall, modifier = Modifier.weight(1f))
            if (state.machines.isNotEmpty()) TextButton(onClick = client::cancelPairing) { Text("Cancel") }
        }
        Text("In Termio on your Mac, open Settings ▸ Mobile, turn off Direct Attach, and scan the QR code.",
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        Button(onClick = {
            focusManager.clearFocus()
            keyboard?.hide()
            cameraDenied = false
            if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
                scanning = true
            } else cameraPermission.launch(Manifest.permission.CAMERA)
        }, modifier = Modifier.fillMaxWidth()) {
            Text("Scan QR Code")
        }
        if (cameraDenied) {
            Text("Allow camera access to scan a QR code, or paste the Mac address below.",
                color = MaterialTheme.colorScheme.error)
            TextButton(onClick = {
                context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.fromParts("package", context.packageName, null)))
            }) { Text("Open Settings") }
        }
        OutlinedTextField(
            value = state.pairingAddress,
            onValueChange = client::editPairingAddress,
            modifier = Modifier.fillMaxWidth(),
            label = { Text("Mac Address") },
            singleLine = true,
            keyboardOptions = KeyboardOptions(
                capitalization = KeyboardCapitalization.None,
                autoCorrectEnabled = false,
                keyboardType = KeyboardType.Uri,
            ),
        )
        Button(onClick = { client.connect(state.pairingAddress) }) {
            Text("Connect")
        }
        if (state.pairingError.isNotEmpty()) Text(state.pairingError, color = MaterialTheme.colorScheme.error)
    }
}

@Composable
private fun SessionList(state: HomeState, client: CompanionClient, modifier: Modifier) {
    val listState = rememberLazyListState()
    var pendingDeletionID by rememberSaveable { mutableStateOf<String?>(null) }
    val pendingDeletion = state.machines.firstOrNull { it.machine.id == pendingDeletionID }?.machine
    if (pendingDeletion != null) AlertDialog(
        onDismissRequest = { pendingDeletionID = null },
        title = { Text("Delete “${pendingDeletion.name}”?") },
        text = { Text("This removes the saved connection from this phone. Sessions on your Mac keep running.") },
        confirmButton = {
            TextButton(onClick = {
                pendingDeletionID = null
                client.deleteMachine(pendingDeletion.id)
            }) { Text("Delete", color = MaterialTheme.colorScheme.error) }
        },
        dismissButton = {
            TextButton(onClick = { pendingDeletionID = null }) { Text("Cancel") }
        },
    )
    LaunchedEffect(state.showingPairing) {
        if (state.showingPairing) listState.scrollToItem(0)
    }
    LazyColumn(modifier.padding(horizontal = 16.dp), state = listState,
        verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if (state.showingPairing || state.machines.isEmpty()) item(key = "pairing") {
            PairPage(state, client, Modifier.fillMaxWidth())
        }
        state.machines.forEach { linked ->
            val machine = linked.machine
            val connection = linked.connection
            item(key = "${machine.id}:name") {
                Row(Modifier.fillMaxWidth().padding(top = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(machine.name, style = MaterialTheme.typography.titleLarge, modifier = Modifier.weight(1f),
                        maxLines = 2, overflow = TextOverflow.Ellipsis)
                    TextButton(onClick = { pendingDeletionID = machine.id }) {
                        Text("Delete", color = MaterialTheme.colorScheme.error)
                    }
                }
            }
            item(key = "${machine.id}:status") {
                if (connection.error.isNotEmpty()) Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(connection.error, color = MaterialTheme.colorScheme.error)
                    Button(onClick = { client.retryMachine(machine.id) }) { Text("Retry") }
                } else Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text(connection.status, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Spacer(Modifier.weight(1f))
                    if (connection.connected) Button(onClick = { client.startTerminal(machine.id) }) { Text("New Terminal") }
                }
            }
            if (connection.connected && connection.error.isEmpty()) {
                if (connection.projects.isEmpty()) item(key = "${machine.id}:empty") {
                    Text("Open a project or start a terminal on your Mac, or tap New Terminal here.")
                }
                connection.projects.groupBy { it.workspaceName }.forEach { (workspace, projects) ->
                    item(key = "${machine.id}:workspace:$workspace") {
                        Text(workspace, style = MaterialTheme.typography.titleSmall,
                            modifier = Modifier.padding(top = 12.dp))
                    }
                    items(projects, key = { "${machine.id}:project:${it.id}" }) { project ->
                        Card(Modifier.fillMaxWidth()) {
                            Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                Text(project.name, style = MaterialTheme.typography.titleMedium)
                                if (project.deviceAlias.isNotEmpty()) Text(project.deviceAlias,
                                    style = MaterialTheme.typography.bodySmall)
                                project.sessions.forEach { session ->
                                    TextButton(onClick = { client.openSession(machine.id, session) }, modifier = Modifier.fillMaxWidth()) {
                                        Column(Modifier.fillMaxWidth()) {
                                            Text(session.title)
                                            Text(listOf(session.agent, session.status).filter { it.isNotEmpty() }.joinToString(" · "),
                                                style = MaterialTheme.typography.bodySmall,
                                                color = MaterialTheme.colorScheme.onSurfaceVariant)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        item { Spacer(Modifier.size(12.dp)) }
    }
}

@Composable
private fun TerminalPage(state: CompanionState, modifier: Modifier) {
    val terminalState = rememberGhosttyTerminalState()
    val inputReady = state.sessionReady && terminalState.view != null
    Column(modifier) {
        Text(state.sessionStatus, modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        GhosttyTerminal(
            session = state.terminal,
            state = terminalState,
            modifier = Modifier.weight(1f).fillMaxWidth().clipToBounds(),
            fontSizeSp = 14f,
            focusOnAttach = true,
            darkColorScheme = true,
        )
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            GhosttyExtraKeysBar(state = terminalState, modifier = Modifier.weight(1f))
            Button(onClick = { terminalState.view?.sendKey(KeyEvent.KEYCODE_ENTER) },
                enabled = inputReady, modifier = Modifier.padding(horizontal = 8.dp)) { Text("Enter") }
        }
    }
    GhosttyDialogs(terminalState)
}
