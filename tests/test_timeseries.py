from modbus_connector.timeseries import TimeSeries


def test_append_points_len() -> None:
    series = TimeSeries()
    series.append(1.0, 10.0)
    series.append(2.0, 20.0)
    assert len(series) == 2
    assert series.points() == ([1.0, 2.0], [10.0, 20.0])


def test_maxlen_evicts_oldest() -> None:
    series = TimeSeries(maxlen=3)
    for i in range(5):
        series.append(float(i), float(i * 10))
    assert len(series) == 3
    assert series.points() == ([2.0, 3.0, 4.0], [20.0, 30.0, 40.0])


def test_stats_in_range() -> None:
    series = TimeSeries()
    for t, v in ((1.0, 10.0), (2.0, 20.0), (3.0, 30.0), (9.0, 99.0)):
        series.append(t, v)
    assert series.stats(1.5, 5.0) == (20.0, 30.0, 25.0)
    assert series.stats(1.0, 9.0) == (10.0, 99.0, 39.75)


def test_stats_empty_range_returns_none() -> None:
    series = TimeSeries()
    assert series.stats(0.0, 1.0) is None
    series.append(10.0, 5.0)
    assert series.stats(0.0, 1.0) is None


def test_clear() -> None:
    series = TimeSeries()
    series.append(1.0, 1.0)
    series.clear()
    assert len(series) == 0
    assert series.points() == ([], [])


def test_recent_values_respects_order_limit_and_eviction() -> None:
    series = TimeSeries(maxlen=4)
    for i in range(10):
        series.append(float(i), float(i))
    assert series.recent_values(2) == [8.0, 9.0]
    assert series.recent_values(10) == [6.0, 7.0, 8.0, 9.0]
    assert series.recent_values(0) == []
    assert series.recent_values(-1) == []
