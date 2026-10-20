"""Independent regression coverage for sync worker failure containment."""
import asyncio
import sqlite3

from smartspend_mcp.sync_service import SyncRepository, create_app


def test_worker_survives_transient_connection_enumeration_failure(tmp_path):
    class Google:
        calls = 0

        def ready_connections(self):
            self.calls += 1
            if self.calls == 1:
                raise sqlite3.OperationalError("database is locked")
            return []

    async def run():
        google = Google()
        app = create_app(SyncRepository(tmp_path), public_url="https://sync.example", google_oauth=google)
        manager = app.router.lifespan_context(app)
        await manager.__aenter__()
        await asyncio.sleep(0.05)
        worker_failed = False
        try:
            await manager.__aexit__(None, None, None)
        except sqlite3.OperationalError:
            worker_failed = True
        assert not worker_failed, "Transient connection discovery failure permanently killed Google sync worker"

    asyncio.run(run())
