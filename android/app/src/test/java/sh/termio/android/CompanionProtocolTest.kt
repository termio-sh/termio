package sh.termio.android

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class CompanionProtocolTest {
    @Test fun pairingRetainsTheEncodedAddressAndDecodesOnlyTheToken() {
        val pairing = CompanionProtocol.pairingAddress(" https://mac.example:8787/path?t=a%2Bb%22&other=1 ")
        assertEquals("wss://mac.example:8787/path?t=a%2Bb%22&other=1", pairing.url)
        assertEquals("a+b\"", pairing.token)
        assertEquals("a+b\"", JSONObject(CompanionProtocol.authentication(pairing.token)).getString("token"))
    }

    @Test fun invalidPairingsDoNotOpenAConnection() {
        for (address in listOf("not an address", "termio://device?token=secret", "ws://mac/", "ws://mac/?t=", "ws://user:secret@mac/?t=secret", "ws://mac:0/?t=secret", "ws://mac:65536/?t=secret")) {
            assertThrows(IllegalArgumentException::class.java) { CompanionProtocol.pairingAddress(address) }
        }
    }

    @Test fun directAttachQrCodesExplainHowToGetACompatibleCode() {
        val error = assertThrows(IllegalArgumentException::class.java) {
            CompanionProtocol.pairingAddress("termio://device?token=secret")
        }
        assertEquals("Turn off Direct Attach in Settings ▸ Mobile on your Mac, then scan the QR code again.", error.message)
        assertFalse(error.message.orEmpty().contains("secret"))
    }

    @Test fun eachSessionAuthenticatesBeforeAttachingAndDeclaringItsViewport() {
        val messages = CompanionProtocol.sessionPreamble("secret", "session", 47, 30).map(::JSONObject)
        assertEquals(listOf("auth", "attach", "resize"), messages.map { it.getString("t") })
        assertEquals(2, messages[0].getInt("wire"))
        assertEquals("session", messages[1].getString("session"))
        assertEquals(47, messages[2].getInt("cols"))
        assertEquals(30, messages[2].getInt("rows"))
        assertTrue(messages[2].getBoolean("rendering"))
        assertFalse(messages[2].has("surfaceCols"))
    }

    @Test fun sharedGridDoesNotReplaceThePhonesViewport() {
        val message = JSONObject(CompanionProtocol.viewport(47, 30, true, 120, 40))
        assertEquals(47, message.getInt("cols"))
        assertEquals(30, message.getInt("rows"))
        assertEquals(120, message.getInt("surfaceCols"))
        assertEquals(40, message.getInt("surfaceRows"))
        assertFalse(JSONObject(CompanionProtocol.viewport(47, 30, false, 47, 30)).getBoolean("rendering"))
    }

    @Test fun rosterKeepsWorkspaceAndSessionIdentity() {
        val roster = JSONObject("""{"projects":[{"id":"project","name":"Example","workspaceID":"workspace","workspaceName":"Work","sessions":[{"id":"session","title":"Deploy 🟢","agent":"terminal","status":"idle"}]}]}""")
        val project = CompanionProtocol.projects(roster).single()
        assertEquals("workspace", project.workspaceID)
        assertEquals("Work", project.workspaceName)
        assertEquals("session", project.sessions.single().id)
        assertEquals("Deploy 🟢", project.sessions.single().title)
        assertTrue(CompanionProtocol.projects(JSONObject()).isEmpty())
    }

    @Test fun refusalsExplainTheActionWithoutRevealingTheAddress() {
        assertTrue(CompanionProtocol.refusal(JSONObject().put("code", "unauthorized")).contains("Scan its QR code again"))
        assertEquals("Update Termio on this phone.", CompanionProtocol.refusal(JSONObject().put("code", "client_too_old")))
    }

    @Test fun savedMachinesRetainTheirNamesIdentitiesAndPairingTokensAfterReload() {
        val machines = listOf(
            PairedMachine("first", "wss://first.example/?t=a%2Bb", "Work \"Mac\"", "mac-first"),
            PairedMachine("second", "ws://second.example:8787/?t=other", "Home Mac", "mac-second"),
        )
        assertEquals(machines, PairedMachines.restore(PairedMachines.encode(machines), null))
    }

    @Test fun legacyPairingMigratesButDoesNotResurrectADeletedMachine() {
        val legacy = "https://first.example/?t=secret"
        val migrated = PairedMachines.restore(null, legacy).single()
        assertEquals("wss://first.example/?t=secret", migrated.address)
        assertEquals("first.example", migrated.name)
        assertEquals(listOf(migrated), PairedMachines.restore(PairedMachines.encode(listOf(migrated)), legacy))
        assertTrue(PairedMachines.restore("[]", legacy).isEmpty())
    }

    @Test fun scanningAnUpdatedTokenKeepsTheMachineIdentityAndName() {
        val original = PairedMachine("first", "wss://first.example/?t=old", "Work Mac", "mac-first")
        val updated = PairedMachines.pair(listOf(original), CompanionProtocol.pairingAddress("wss://FIRST.example:443/?t=new"))
        assertEquals(original.id, updated.id)
        assertEquals(original.name, updated.name)
        assertEquals(original.macID, updated.macID)
        assertEquals("new", CompanionProtocol.pairingAddress(updated.address).token)
        val other = PairedMachines.pair(listOf(original), CompanionProtocol.pairingAddress("wss://first.example/other?t=new"))
        assertNotEquals(original.id, other.id)
    }

    @Test fun differentMachinesKeepIndependentIdentityEvenWithTheSameSessionID() {
        val first = PairedMachine("first", "ws://first.example/?t=one", "First Mac")
        val second = PairedMachines.pair(listOf(first), CompanionProtocol.pairingAddress("ws://second.example/?t=two"))
            .copy(name = "Second Mac")
        assertNotEquals(first.id, second.id)
        val home = HomeState(machines = listOf(
            MachineState(first, CompanionState(macName = first.name, session = RemoteSession("session", "First terminal"))),
            MachineState(second, CompanionState(macName = second.name, session = RemoteSession("session", "Second terminal"))),
        ), selectedMachineID = second.id)
        assertEquals("Second terminal", home.selectedConnection?.session?.title)
        assertEquals("Second Mac", home.selectedConnection?.macName)
    }

    @Test fun macIdentityUpdatesAnExistingLinkWhenItsTunnelChanges() {
        val original = PairedMachine("first", "wss://old.example/?t=old", "Work Mac", "mac-first")
        val pending = PairedMachines.pair(listOf(original), CompanionProtocol.pairingAddress("wss://new.example/?t=new"))
        val identified = PairedMachines.identify(listOf(original, pending), pending, "mac-first", "Renamed Mac")
        assertEquals(original.id, identified.id)
        assertEquals(pending.address, identified.address)
        assertEquals("Renamed Mac", identified.name)
        assertEquals(pending.id, PairedMachines.identify(listOf(original, pending), pending, "", "").id)
    }
}
