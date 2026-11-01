import tempfile
from pathlib import Path
from app import ClientStore


def test_client_store_persistence():
    with tempfile.TemporaryDirectory() as tmpdir:
        store_file = Path(tmpdir) / "clients.json"
        store = ClientStore(file_path=store_file)

        # Initially empty
        assert store.load_clients() == set()

        # Add clients
        uuid1 = "a2b9d4e1-73c5-4812-b964-f3e7b85a1901"
        uuid2 = "a2b9d4e1-73c5-4812-b964-f3e7b85a1902"
        store.add_client(uuid1)
        store.add_client(uuid2)

        clients = store.load_clients()
        assert uuid1 in clients
        assert uuid2 in clients
        assert len(clients) == 2

        # Remove client
        store.remove_client(uuid1)
        clients_after = store.load_clients()
        assert uuid1 not in clients_after
        assert uuid2 in clients_after
        assert len(clients_after) == 1


def test_epoch_manager_find_xray_process_fast_path():
    from unittest.mock import patch
    from epoch_manager import EpochManager

    with tempfile.TemporaryDirectory() as tmpdir:
        em = EpochManager(
            file_path=str(Path(tmpdir) / "epoch.json"),
            lock_path=str(Path(tmpdir) / "epoch.lock"),
        )
        em._last_pid = 4321
        em._last_starttime = 99999

        with patch.object(em, "_is_xray_process", return_value=True) as mock_is_xray, \
             patch.object(em, "_read_proc_stat", return_value=99999) as mock_read_stat, \
             patch("pathlib.Path.iterdir") as mock_iterdir:
            pid, starttime = em._find_xray_process()
            assert pid == 4321
            assert starttime == 99999
            mock_is_xray.assert_called_once_with(4321)
            mock_read_stat.assert_called_once_with(4321)
            mock_iterdir.assert_not_called()
