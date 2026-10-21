package sh.termio.android

import android.app.Application
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import io.github.sagernet.libghostty.GhosttyTerminalSession
import java.net.URI
import java.net.URLDecoder
import java.util.concurrent.TimeUnit
import java.util.UUID
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import org.json.JSONArray
import org.json.JSONObject

data class RemoteSession(val id: String, val title: String, val agent: String = "", val status: String = "")
data class RemoteProject(val id: String, val name: String, val workspaceID: String,
    val workspaceName: String, val deviceAlias: String, val sessions: List<RemoteSession>)
data class CompanionState(
    val address: String = "",
    val macName: String = "Termio",
    val macID: String = "",
    val status: String = "",
    val error: String = "",
    val connected: Boolean = false,
    val hasRoster: Boolean = false,
    val projects: List<RemoteProject> = emptyList(),
    val session: RemoteSession? = null,
    val terminal: GhosttyTerminalSession? = null,
    val sessionStatus: String = "Connecting…",
    val sessionReady: Boolean = false,
)

data class PairingAddress(val url: String, val token: String)

data class PairedMachine(val id: String, val address: String, val name: String, val macID: String = "")
data class MachineState(val machine: PairedMachine, val connection: CompanionState)
data class HomeState(
    val machines: List<MachineState> = emptyList(),
    val selectedMachineID: String? = null,
    val showingPairing: Boolean = false,
    val pairingAddress: String = "",
    val pairingError: String = "",
) {
    val selectedConnection: CompanionState?
        get() = machines.firstOrNull { it.machine.id == selectedMachineID }?.connection
}

object PairedMachines {
    fun encode(machines: List<PairedMachine>): String = JSONArray().apply {
        machines.forEach { machine ->
            put(JSONObject().put("id", machine.id).put("address", machine.address)
                .put("name", machine.name).put("macID", machine.macID))
        }
    }.toString()

    fun restore(saved: String?, legacyAddress: String?): List<PairedMachine> {
        if (saved == null) {
            return legacyAddress?.takeIf { it.isNotEmpty() }?.let {
                listOf(pair(emptyList(), CompanionProtocol.pairingAddress(it)))
            }.orEmpty()
        }
        val rows = JSONArray(saved)
        return (0 until rows.length()).map { index ->
            val row = rows.getJSONObject(index)
            val address = CompanionProtocol.pairingAddress(row.getString("address"))
            val id = row.getString("id")
            require(id.isNotEmpty()) { "The saved Mac has no identity." }
            PairedMachine(id, address.url, row.optString("name").ifEmpty { URI(address.url).host },
                if (row.isNull("macID")) "" else row.optString("macID"))
        }.distinctBy { it.id }
    }

    fun pair(machines: List<PairedMachine>, address: PairingAddress): PairedMachine {
        val existing = machines.firstOrNull { endpoint(it.address) == endpoint(address.url) }
        return existing?.copy(address = address.url)
            ?: PairedMachine(UUID.randomUUID().toString(), address.url, URI(address.url).host)
    }

    fun identify(machines: List<PairedMachine>, machine: PairedMachine, macID: String, name: String): PairedMachine {
        val existing = machines.firstOrNull { macID.isNotEmpty() && it.macID == macID && it.id != machine.id }
        return machine.copy(id = existing?.id ?: machine.id, name = name.ifEmpty { machine.name }, macID = macID)
    }

    private fun endpoint(address: String): List<String> {
        val uri = URI(address)
        val port = if (uri.port == -1) { if (uri.scheme == "wss") 443 else 80 } else uri.port
        return listOf(uri.scheme.lowercase(), uri.host.lowercase(), port.toString(), uri.rawPath.ifEmpty { "/" },
            uri.rawQuery.orEmpty().split('&').filter { it.substringBefore('=') != "t" }.sorted().joinToString("&"))
    }
}

object CompanionProtocol {
    const val wireVersion = 2

    fun pairingAddress(raw: String): PairingAddress {
        val uri = try { URI(raw.trim()) } catch (_: Exception) {
            throw IllegalArgumentException("Scan the QR code or copy the address from Settings ▸ Mobile on your Mac.")
        }
        require(uri.scheme?.lowercase() != "termio" || uri.host != "device") {
            "Turn off Direct Attach in Settings ▸ Mobile on your Mac, then scan the QR code again."
        }
        val scheme = when (uri.scheme?.lowercase()) {
            "ws", "http" -> "ws"
            "wss", "https" -> "wss"
            else -> throw IllegalArgumentException("Scan the QR code or copy the address from Settings ▸ Mobile on your Mac.")
        }
        require(!uri.host.isNullOrEmpty() && uri.rawUserInfo == null && (uri.port == -1 || uri.port in 1..65535)) {
            "Scan the QR code or copy the address from Settings ▸ Mobile on your Mac."
        }
        val token = uri.rawQuery.orEmpty().split('&').firstNotNullOfOrNull { field ->
            val parts = field.split('=', limit = 2)
            if (parts.size == 2 && parts[0] == "t") URLDecoder.decode(parts[1], "UTF-8") else null
        }
        require(!token.isNullOrEmpty()) { "The address has no pairing token. Scan or copy it again from your Mac." }
        val url = scheme + ":" + uri.rawSchemeSpecificPart
        return PairingAddress(url, token)
    }

    fun authentication(token: String): String = JSONObject()
        .put("t", "auth").put("token", token).put("wire", wireVersion).toString()

    fun sessionPreamble(token: String, sessionID: String, columns: Int, rows: Int): List<String> =
        listOf(authentication(token), JSONObject().put("t", "attach").put("session", sessionID).toString(),
            viewport(columns, rows, true, columns, rows))

    fun viewport(columns: Int, rows: Int, rendering: Boolean, surfaceColumns: Int, surfaceRows: Int): String {
        val control = JSONObject().put("t", "resize").put("cols", columns).put("rows", rows)
            .put("rendering", rendering)
        if (surfaceColumns > 0 && surfaceRows > 0 && (surfaceColumns != columns || surfaceRows != rows)) {
            control.put("surfaceCols", surfaceColumns).put("surfaceRows", surfaceRows)
        }
        return control.toString()
    }

    fun projects(roster: JSONObject): List<RemoteProject> {
        val projects = roster.optJSONArray("projects") ?: return emptyList()
        return (0 until projects.length()).mapNotNull { index ->
            val project = projects.optJSONObject(index) ?: return@mapNotNull null
            val id = project.optString("id")
            if (id.isEmpty()) return@mapNotNull null
            val sessions = project.optJSONArray("sessions")
            val rows = if (sessions == null) emptyList() else (0 until sessions.length()).mapNotNull { row ->
                val session = sessions.optJSONObject(row) ?: return@mapNotNull null
                val sessionID = session.optString("id")
                if (sessionID.isEmpty()) null else RemoteSession(sessionID,
                    session.optString("title").ifEmpty { session.optString("name", "Session") },
                    session.optString("agent"), session.optString("status"))
            }
            RemoteProject(id, project.optString("name", "Project"), project.optString("workspaceID"),
                project.optString("workspaceName", "Workspace"), project.optString("deviceAlias"), rows)
        }
    }

    fun refusal(message: JSONObject): String = when (message.optString("code")) {
        "unauthorized" -> "This Mac didn’t recognize this phone. Scan its QR code again in Settings ▸ Mobile."
        "client_too_old" -> "Update Termio on this phone."
        else -> message.optString("message", "The Mac refused the request.")
    }
}

class CompanionClient(application: Application) : AndroidViewModel(application) {
    private class MachineLink(var machine: PairedMachine, val connection: MacConnection, var observation: Job? = null)

    private val preferences = application.getSharedPreferences("companion", Application.MODE_PRIVATE)
    private val client = OkHttpClient.Builder().pingInterval(20, TimeUnit.SECONDS).build()
    private val links = linkedMapOf<String, MachineLink>()
    private val mutableState = MutableStateFlow(HomeState())
    val state = mutableState.asStateFlow()
    private var foreground = false

    init {
        val saved = try {
            PairedMachines.restore(preferences.getString("machines", null), preferences.getString("address", null))
        } catch (failure: Exception) {
            Log.w("CompanionClient", "Saved Macs could not be read: ${failure.javaClass.simpleName}")
            mutableState.update { it.copy(pairingError = "Couldn’t read saved Macs. Scan their QR codes again.") }
            emptyList()
        }
        saved.forEach(::addLink)
        if (saved.isNotEmpty()) saveMachines()
        publish()
    }

    fun beginPairing() {
        mutableState.update { it.copy(showingPairing = true, pairingAddress = "", pairingError = "") }
    }

    fun cancelPairing() {
        mutableState.update { it.copy(showingPairing = false, pairingAddress = "", pairingError = "") }
    }

    fun editPairingAddress(address: String) {
        mutableState.update { it.copy(pairingAddress = address, pairingError = "") }
    }

    fun connect(address: String) {
        val parsed = try { CompanionProtocol.pairingAddress(address) } catch (failure: IllegalArgumentException) {
            mutableState.update { it.copy(pairingError = failure.message.orEmpty()) }
            return
        }
        val machine = PairedMachines.pair(links.values.map { it.machine }, parsed)
        links[machine.id]?.let(::closeLink)
        addLink(machine)
        saveMachines()
        mutableState.update { it.copy(showingPairing = false, pairingAddress = "", pairingError = "") }
        publish()
    }

    private fun addLink(machine: PairedMachine) {
        val connection = MacConnection(getApplication(), client)
        val link = MachineLink(machine, connection)
        links[machine.id] = link
        connection.onStarted = { session ->
            if (state.value.selectedMachineID == link.machine.id) openSession(link.machine.id, session)
        }
        link.observation = viewModelScope.launch {
            connection.state.collect { current ->
                if (links[link.machine.id] !== link) return@collect
                if (current.connected) {
                    val identified = PairedMachines.identify(links.values.map { it.machine }, link.machine,
                        current.macID, current.macName)
                    if (identified != link.machine) {
                        if (identified.id != link.machine.id) {
                            links[identified.id]?.let(::closeLink)
                            links.remove(link.machine.id)
                            links[identified.id] = link
                        }
                        link.machine = identified
                        saveMachines()
                    }
                }
                publish()
            }
        }
        connection.connect(machine.address)
    }

    private fun publish() {
        mutableState.update { home ->
            home.copy(machines = links.values.map { MachineState(it.machine, it.connection.state.value) })
        }
    }

    private fun saveMachines() {
        val saved = PairedMachines.encode(links.values.map { it.machine })
        if (saved != preferences.getString("machines", null) || preferences.contains("address")) {
            preferences.edit().putString("machines", saved).remove("address").apply()
        }
    }

    fun retryMachine(id: String) {
        links[id]?.let { it.connection.connect(it.machine.address) }
    }

    fun deleteMachine(id: String) {
        val link = links.remove(id) ?: return
        closeLink(link)
        saveMachines()
        publish()
    }

    private fun closeLink(link: MachineLink) {
        if (state.value.selectedMachineID == link.machine.id) leaveSession()
        link.observation?.cancel()
        link.connection.close()
    }

    fun startTerminal(machineID: String) {
        val connection = links[machineID]?.connection ?: return
        if (!connection.state.value.connected) return
        leaveSession()
        mutableState.update { it.copy(selectedMachineID = machineID) }
        connection.setForeground(foreground)
        connection.startTerminal()
    }

    fun openSession(machineID: String, session: RemoteSession) {
        val connection = links[machineID]?.connection ?: return
        if (!connection.state.value.connected) return
        leaveSession()
        mutableState.update { it.copy(selectedMachineID = machineID) }
        connection.setForeground(foreground)
        connection.openSession(session)
    }

    fun leaveSession() {
        links[state.value.selectedMachineID]?.connection?.let {
            it.setForeground(false)
            it.leaveSession()
        }
        mutableState.update { it.copy(selectedMachineID = null) }
    }

    fun setForeground(visible: Boolean) {
        foreground = visible
        links.values.forEach { it.connection.setForeground(visible && it.machine.id == state.value.selectedMachineID) }
    }

    override fun onCleared() {
        links.values.forEach(::closeLink)
        client.dispatcher.executorService.shutdown()
        client.connectionPool.evictAll()
    }
}

private class MacConnection(private val application: Application, private val client: OkHttpClient) {
    var onStarted: (RemoteSession) -> Unit = {}
    private val handler = Handler(Looper.getMainLooper())
    private val mutableState = MutableStateFlow(CompanionState())
    val state = mutableState.asStateFlow()
    private var pairing: PairingAddress? = null
    private var rosterSocket: WebSocket? = null
    private var sessionSocket: WebSocket? = null
    private var foreground = false
    private var sessionAuthenticated = false
    private var applyingSharedGrid = false
    private var viewportColumns = 80
    private var viewportRows = 24
    private var cellWidthPixels = 0
    private var cellHeightPixels = 0
    private val retrySession = Runnable { if (state.value.session != null) dialSession() }
    private val rosterTimeout = Runnable {
        if (!state.value.connected && rosterSocket != null) rosterDisconnected(rosterSocket)
    }

    fun connect(address: String) {
        val parsed = try { CompanionProtocol.pairingAddress(address) } catch (error: IllegalArgumentException) {
            mutableState.update { it.copy(error = error.message.orEmpty(), status = "") }
            return
        }
        stopConnections()
        pairing = parsed
        mutableState.value = CompanionState(address = parsed.url, status = "Connecting…")
        dialRoster()
    }

    private fun dialRoster() {
        val address = pairing ?: return
        handler.removeCallbacks(rosterTimeout)
        mutableState.update { it.copy(status = "Connecting…", connected = false) }
        rosterSocket = client.newWebSocket(Request.Builder().url(address.url).build(), object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                handler.post { if (webSocket === rosterSocket) webSocket.send(CompanionProtocol.authentication(address.token)) }
            }
            override fun onMessage(webSocket: WebSocket, text: String) {
                handler.post { if (webSocket === rosterSocket) receiveRoster(text) }
            }
            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                Log.w("CompanionClient", "Roster connection failed: ${t.javaClass.simpleName}")
                handler.post { rosterDisconnected(webSocket) }
            }
            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) { webSocket.close(code, null) }
            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                handler.post { rosterDisconnected(webSocket) }
            }
        })
        handler.postDelayed(rosterTimeout, 15000)
    }

    private fun receiveRoster(text: String) {
        val message = decode(text) ?: return
        when (message.optString("t")) {
            "roster" -> {
                if (message.optInt("wire") < CompanionProtocol.wireVersion) {
                    stopConnections()
                    mutableState.update { it.copy(connected = false,
                        error = "Update Termio on your Mac to connect this phone.", status = "") }
                    return
                }
                handler.removeCallbacks(rosterTimeout)
                mutableState.update { it.copy(hasRoster = true, connected = true, status = "Connected", error = "",
                    macName = if (message.isNull("macName")) "" else message.optString("macName"),
                    macID = if (message.isNull("macID")) "" else message.optString("macID"),
                    projects = CompanionProtocol.projects(message)) }
            }
            "started" -> {
                val id = message.optString("session")
                if (id.isNotEmpty()) onStarted(RemoteSession(id, "Terminal"))
            }
            "error" -> {
                if (!state.value.hasRoster || message.optString("code") in listOf("unauthorized", "client_too_old")) {
                    stopConnections()
                    mutableState.update { it.copy(status = "", connected = false, error = CompanionProtocol.refusal(message)) }
                } else mutableState.update { it.copy(error = CompanionProtocol.refusal(message)) }
            }
        }
    }

    private fun rosterDisconnected(socket: WebSocket?) {
        if (socket !== rosterSocket || pairing == null) return
        stopConnections()
        mutableState.update { it.copy(connected = false, status = "",
            error = "Couldn’t connect to this Mac. Check Mobile Access on your Mac, then tap Retry.") }
    }

    fun startTerminal() {
        if (!state.value.connected) return
        val control = JSONObject().put("t", "startTerminal")
        state.value.projects.firstOrNull()?.workspaceID?.takeIf { it.isNotEmpty() }?.let { control.put("workspace", it) }
        mutableState.update { it.copy(error = "") }
        rosterSocket?.send(control.toString())
    }

    fun openSession(session: RemoteSession) {
        leaveSession()
        mutableState.update { it.copy(session = session, sessionStatus = "Connecting…") }
        dialSession()
    }

    private fun dialSession() {
        val address = pairing ?: return
        val selected = state.value.session ?: return
        handler.removeCallbacks(retrySession)
        closeSessionSocket()
        state.value.terminal?.close()
        val terminal = GhosttyTerminalSession(application)
        terminal.transport = object : GhosttyTerminalSession.Transport {
            override fun sendInput(data: ByteArray) {
                handler.post { if (state.value.terminal === terminal) this@MacConnection.sendInput(data) }
            }
            override fun sendResize(columns: Int, rows: Int, widthPixels: Int, heightPixels: Int) {
                if (applyingSharedGrid || state.value.terminal !== terminal) return
                viewportColumns = columns
                viewportRows = rows
                cellWidthPixels = widthPixels / columns.coerceAtLeast(1)
                cellHeightPixels = heightPixels / rows.coerceAtLeast(1)
                reportViewport()
            }
            // The companion client owns the socket, separately from the renderer.
            override fun close() {}
        }
        mutableState.update { it.copy(terminal = terminal, sessionReady = false, sessionStatus = "Connecting…") }
        sessionSocket = client.newWebSocket(Request.Builder().url(address.url).build(), object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                handler.post {
                    if (webSocket === sessionSocket) {
                        CompanionProtocol.sessionPreamble(address.token, selected.id, viewportColumns, viewportRows)
                            .forEach { webSocket.send(it) }
                        sessionAuthenticated = true
                        reportViewport()
                    }
                }
            }
            override fun onMessage(webSocket: WebSocket, text: String) {
                handler.post { if (webSocket === sessionSocket) receiveSession(text) }
            }
            override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                // Preserve the grid-control/frame order on the same queue.
                handler.post { if (webSocket === sessionSocket) terminal.feedOutput(bytes.toByteArray()) }
            }
            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                Log.w("CompanionClient", "Session connection failed: ${t.javaClass.simpleName}")
                handler.post { sessionDisconnected(webSocket) }
            }
            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) { webSocket.close(code, null) }
            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                handler.post { sessionDisconnected(webSocket) }
            }
        })
    }

    private fun receiveSession(text: String) {
        val message = decode(text) ?: return
        when (message.optString("t")) {
            "roster" -> {
                if (message.optInt("wire") < CompanionProtocol.wireVersion) {
                    finishSession("Update Termio on your Mac to connect this phone.")
                } else mutableState.update { it.copy(sessionReady = true, sessionStatus = "Connected") }
            }
            "grid" -> {
                val columns = message.optInt("cols")
                val rows = message.optInt("rows")
                val terminal = state.value.terminal ?: return
                if (columns !in 1..4096 || rows !in 1..2048) {
                    finishSession("The Mac sent an invalid terminal size. Reconnect to this session.")
                    return
                }
                // The shared grid describes the incoming bytes, not this phone's viewport.
                applyingSharedGrid = true
                try {
                    val transport = terminal.transport
                    terminal.transport = null
                    terminal.resize(columns, rows, cellWidthPixels, cellHeightPixels)
                    terminal.transport = transport
                } finally {
                    applyingSharedGrid = false
                }
                reportViewport()
            }
            "exit" -> finishSession("Ended")
            "error" -> finishSession(CompanionProtocol.refusal(message))
        }
    }

    private fun sessionDisconnected(socket: WebSocket) {
        if (socket !== sessionSocket || state.value.session == null) return
        sessionAuthenticated = false
        mutableState.update { it.copy(sessionReady = false, sessionStatus = "Reconnecting…") }
        handler.removeCallbacks(retrySession)
        handler.postDelayed(retrySession, 2500)
    }

    private fun finishSession(status: String) {
        handler.removeCallbacks(retrySession)
        closeSessionSocket()
        state.value.terminal?.finish()
        mutableState.update { it.copy(sessionReady = false, sessionStatus = status) }
    }

    fun sendInput(data: ByteArray) {
        if (state.value.sessionReady) sessionSocket?.send(data.toByteString())
    }

    fun setForeground(visible: Boolean) {
        foreground = visible
        reportViewport()
    }

    private fun reportViewport(rendering: Boolean = foreground) {
        val terminal = state.value.terminal ?: return
        if (!sessionAuthenticated || viewportColumns < 1 || viewportRows < 1) return
        sessionSocket?.send(CompanionProtocol.viewport(viewportColumns, viewportRows, rendering,
            terminal.columns, terminal.rows))
    }

    fun leaveSession() {
        handler.removeCallbacks(retrySession)
        reportViewport(false)
        closeSessionSocket()
        state.value.terminal?.close()
        mutableState.update { it.copy(session = null, terminal = null, sessionReady = false) }
    }

    private fun closeSessionSocket() {
        sessionAuthenticated = false
        val socket = sessionSocket
        sessionSocket = null
        socket?.cancel()
    }

    private fun stopConnections() {
        handler.removeCallbacks(rosterTimeout)
        handler.removeCallbacks(retrySession)
        leaveSession()
        pairing = null
        val socket = rosterSocket
        rosterSocket = null
        socket?.cancel()
    }

    private fun decode(text: String): JSONObject? = try { JSONObject(text) } catch (error: Exception) {
        Log.w("CompanionClient", "Unreadable companion control: ${error.javaClass.simpleName}")
        null
    }

    fun close() {
        stopConnections()
    }
}
