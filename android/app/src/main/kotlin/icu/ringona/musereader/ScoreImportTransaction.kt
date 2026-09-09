package icu.ringona.musereader

import java.io.File
import java.io.IOException
import java.util.UUID

/** Keep the current collection intact until every replacement file is copied. */
internal fun replaceImportedScores(
    directory: File,
    populate: (File) -> List<String>,
): List<String> {
    val parent = requireNotNull(directory.parentFile)
    val transaction = UUID.randomUUID().toString()
    val staging = File(parent, "imports-$transaction.staging")
    val backup = File(parent, "imports-$transaction.backup")
    check(staging.mkdir()) { "Cannot prepare the import directory." }
    try {
        val names = populate(staging)
        if (!directory.renameTo(backup)) {
            throw IOException("Cannot preserve the previous collection.")
        }
        if (!staging.renameTo(directory)) {
            if (!backup.renameTo(directory)) {
                throw IOException("Cannot restore the collection; files remain at $backup.")
            }
            throw IOException("Cannot install the imported collection.")
        }
        backup.deleteRecursively()
        return names.map { File(directory, it).absolutePath }
    } finally {
        staging.deleteRecursively()
    }
}
