package com.example.nastok.data.db

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase

@Database(
    entities = [VideoEntity::class, InteractionEntity::class, FolderAvatarEntity::class],
    version = 4,
    exportSchema = false
)
abstract class AppDatabase : RoomDatabase() {
    abstract fun videoDao(): VideoDao
    abstract fun interactionDao(): InteractionDao
    abstract fun folderAvatarDao(): FolderAvatarDao

    companion object {
        @Volatile private var INSTANCE: AppDatabase? = null

        /** v2 → v3: add the `watchedAt` column. A real migration (not destructive)
         *  so existing likes/favorites are preserved. */
        private val MIGRATION_2_3 = object : Migration(2, 3) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL(
                    "ALTER TABLE interactions ADD COLUMN watchedAt INTEGER NOT NULL DEFAULT 0"
                )
            }
        }

        /** v3 → v4: add the folder_avatars table (rebuilt on next scan). */
        private val MIGRATION_3_4 = object : Migration(3, 4) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL(
                    "CREATE TABLE IF NOT EXISTS folder_avatars (" +
                        "folderPath TEXT NOT NULL PRIMARY KEY, " +
                        "imagePath TEXT NOT NULL)"
                )
            }
        }

        fun get(context: Context): AppDatabase =
            INSTANCE ?: synchronized(this) {
                INSTANCE ?: Room.databaseBuilder(
                    context.applicationContext,
                    AppDatabase::class.java,
                    "nastok.db"
                ).addMigrations(MIGRATION_2_3, MIGRATION_3_4)
                    // videos table is a rebuildable index, so a destructive fallback
                    // for any unhandled migration is acceptable; interactions are guarded
                    // by the explicit migration above.
                    .fallbackToDestructiveMigration()
                    .build().also { INSTANCE = it }
            }
    }
}
