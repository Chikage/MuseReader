package icu.ringona.musereader

import java.io.File
import java.io.IOException
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ScoreImportTransactionTest {
    @get:Rule
    val temporary = TemporaryFolder()

    @Test
    fun copyFailurePreservesTheOldCollectionAndRemovesPartialCopies() {
        val directory = temporary.newFolder("imports")
        val old = File(directory, "old.mscx").apply { writeText("old score") }
        val failure = IOException("provider disconnected")

        val thrown = runCatching {
            replaceImportedScores(directory) { staging ->
                File(staging, "new.mscx").writeText("partial score")
                throw failure
            }
        }.exceptionOrNull()

        assertSame(failure, thrown)
        assertEquals("old score", old.readText())
        assertEquals(listOf("imports"), temporary.root.listFiles()!!.map { it.name })
        assertEquals(listOf("old.mscx"), directory.listFiles()!!.map { it.name })
    }

    @Test
    fun successfulImportReplacesTheCollectionAndReturnsPersistentPathsInOrder() {
        val directory = temporary.newFolder("imports")
        File(directory, "old.mscx").writeText("old score")
        File(directory, "cache").mkdir()
        val names = listOf("2_a.mscx", "1_b.mscz")

        val imported = replaceImportedScores(directory) { staging ->
            names.forEach { File(staging, it).writeText(it) }
            assertTrue(File(directory, "old.mscx").exists())
            names
        }

        assertEquals(names.map { File(directory, it).absolutePath }, imported)
        assertEquals(names, imported.map { File(it).readText() })
        assertFalse(File(directory, "old.mscx").exists())
        assertFalse(File(directory, "cache").exists())
        assertEquals(listOf("imports"), temporary.root.listFiles()!!.map { it.name })
    }

    @Test
    fun confirmedEmptyImportReplacesTheCollectionWithAnEmptyDirectory() {
        val directory = temporary.newFolder("imports")
        File(directory, "old.mscx").writeText("old score")

        assertTrue(replaceImportedScores(directory) { emptyList() }.isEmpty())
        assertTrue(directory.isDirectory)
        assertTrue(directory.listFiles()!!.isEmpty())
    }
}
