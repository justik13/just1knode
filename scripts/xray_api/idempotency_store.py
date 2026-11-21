import json
import logging
import sqlite3
import time
import uuid as uuid_lib
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Dict, Iterator

logger = logging.getLogger("xray_api.idempotency")


class DurableIdempotencyStore:
    """Persistent SQLite-backed store for durable idempotent operations.

    Ensures idempotent operation records survive process restarts, crashes, and OOM kills.
    Guarantees every database connection is strictly closed on exit.
    """

    def __init__(self, db_path: Path):
        self.db_path = db_path
        self._init_db()

    @contextmanager
    def _get_conn(self) -> Iterator[sqlite3.Connection]:
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        conn = sqlite3.connect(str(self.db_path), timeout=10.0)
        try:
            conn.execute("PRAGMA journal_mode=WAL")
            conn.execute("PRAGMA synchronous=NORMAL")
            with conn:
                yield conn
        finally:
            conn.close()

    def _init_db(self) -> None:
        try:
            with self._get_conn() as conn:
                conn.execute(
                    """
                    CREATE TABLE IF NOT EXISTS idempotent_ops (
                        idempotency_key TEXT PRIMARY KEY,
                        response_json TEXT NOT NULL,
                        created_at REAL NOT NULL,
                        client_id TEXT
                    )
                    """
                )
                try:
                    conn.execute("ALTER TABLE idempotent_ops ADD COLUMN client_id TEXT")
                except sqlite3.OperationalError:
                    pass
                conn.execute(
                    "CREATE INDEX IF NOT EXISTS idx_idempotent_ops_created ON idempotent_ops(created_at)"
                )
                conn.execute(
                    "CREATE INDEX IF NOT EXISTS idx_idempotent_ops_client_id ON idempotent_ops(client_id)"
                )
            try:
                self.db_path.chmod(0o660)
            except Exception:
                pass
        except Exception as e:
            logger.warning(
                "Failed to initialize idempotency db at %s: %s", self.db_path, e
            )

    def get(self, key: str, default: Any = None) -> Any:
        try:
            with self._get_conn() as conn:
                cur = conn.execute(
                    "SELECT response_json FROM idempotent_ops WHERE idempotency_key = ?",
                    (key,),
                )
                row = cur.fetchone()
                if row:
                    return json.loads(row[0])
        except Exception as e:
            logger.warning("Failed to read idempotent op %s: %s", key, e)
        return default

    def set(self, key: str, response: Dict[str, Any]) -> None:
        try:
            now_ts = time.time()
            data_str = json.dumps(response)
            client_id_val = None
            if isinstance(response, dict):
                raw_cid = response.get("client_id")
                if raw_cid:
                    try:
                        client_id_val = str(uuid_lib.UUID(str(raw_cid).strip())).lower()
                    except Exception:
                        client_id_val = str(raw_cid).strip().lower()

            with self._get_conn() as conn:
                conn.execute(
                    """
                    INSERT INTO idempotent_ops (idempotency_key, response_json, created_at, client_id)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(idempotency_key) DO UPDATE SET
                        response_json=excluded.response_json,
                        created_at=excluded.created_at,
                        client_id=excluded.client_id
                    """,
                    (key, data_str, now_ts, client_id_val),
                )
                cur = conn.execute("SELECT COUNT(*) FROM idempotent_ops")
                count = cur.fetchone()[0]
                if count > 2000:
                    conn.execute(
                        """
                        DELETE FROM idempotent_ops WHERE idempotency_key IN (
                            SELECT idempotency_key FROM idempotent_ops
                            ORDER BY created_at ASC LIMIT 500
                        )
                        """
                    )
        except Exception as e:
            logger.warning("Failed to persist idempotent op %s: %s", key, e)

    def __contains__(self, key: str) -> bool:
        return self.get(key) is not None

    def __getitem__(self, key: str) -> Dict[str, Any]:
        val = self.get(key)
        if val is None:
            raise KeyError(key)
        return val

    def __setitem__(self, key: str, response: Dict[str, Any]) -> None:
        self.set(key, response)

    def __len__(self) -> int:
        try:
            with self._get_conn() as conn:
                cur = conn.execute("SELECT COUNT(*) FROM idempotent_ops")
                return cur.fetchone()[0]
        except Exception:
            return 0

    def evict_by_client_id(self, client_id: str) -> None:
        try:
            norm_target = str(uuid_lib.UUID(client_id.strip())).lower()
        except Exception:
            norm_target = client_id.strip().lower()

        try:
            with self._get_conn() as conn:
                conn.execute(
                    "DELETE FROM idempotent_ops WHERE client_id = ?",
                    (norm_target,),
                )
        except Exception as e:
            logger.warning("Failed to evict idempotent ops for client %s: %s", client_id, e)

    def pop(self, key: str, default: Any = None) -> Any:
        try:
            val = self.get(key)
            if val is not None:
                with self._get_conn() as conn:
                    conn.execute("DELETE FROM idempotent_ops WHERE idempotency_key = ?", (key,))
                return val
        except Exception:
            pass
        return default
