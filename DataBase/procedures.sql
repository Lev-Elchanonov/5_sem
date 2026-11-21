CREATE OR REPLACE PROCEDURE cancel_trip(
    IN  p_trip_id         INTEGER,
    IN  p_reason          TEXT,
    IN  p_responsible_id  INTEGER,
    OUT o_order_number    VARCHAR
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_trip       RECORD;
    v_first_stop RECORD;
    v_total      INT;
    v_active     INT;
    v_completed  INT;
    v_order_id   INT;
BEGIN
    SELECT * INTO v_trip -- проверка что рейс существует и его запись в v_trip
    FROM Trip
    WHERE trip_id = p_trip_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Error: Рейс % не найден', p_trip_id;
    END IF;

    -- тут проверка, что ответственный существует. Если не существует, то выкидываем исключение
    PERFORM 1
    FROM Responsible
    WHERE responsible_id = p_responsible_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Error: Ответственный сотрудник % не найден', p_responsible_id;
    END IF;

    -- Тут крч оценка состояния рейса
    SELECT
        COUNT(*), -- считаем все остановки
        COUNT(*) FILTER (WHERE status <> 'cancelled'), -- считаем все неотмененные остановки (если все cancelled, то рейс отменен)
        COUNT(*) FILTER (WHERE status =  'completed') -- считаем все завершенные остановки
    INTO v_total, v_active, v_completed
    FROM Trip_stop
    WHERE trip_id = p_trip_id;

    IF v_total = 0 THEN
        RAISE EXCEPTION 'У рейса % нет остановок — отменять нечего', p_trip_id;
    END IF;
    IF v_active = 0 THEN -- если нет активных, то рейс уже отменен
        RAISE EXCEPTION 'Рейс % уже отменён', p_trip_id;
    END IF;
    IF v_active = v_completed THEN -- если колво активных = колву завершенных, то рейс уже завершен
        RAISE EXCEPTION 'Рейс % уже завершён', p_trip_id;
    END IF;

    -- Проверка что уже отправились с 1ой неотмененной остановки
    SELECT * INTO v_first_stop
    FROM Trip_stop
    WHERE trip_id = p_trip_id AND status <> 'cancelled'
    ORDER BY planned_arrival NULLS LAST, stop_id
    LIMIT 1;

    IF FOUND AND v_first_stop.actual_departure IS NOT NULL THEN -- если запись существует и есть времфя реального отправления, то рейс отменить нельзя
        RAISE EXCEPTION
            'Error: Нельзя отменить рейс %: зафиксировано фактическое отправление с первой активной остановки (stop_id=%, %)',
            p_trip_id, v_first_stop.stop_id, v_first_stop.actual_departure;
    END IF;

    -- После этого я отменяю все неотмененные остановки у рейса
    UPDATE Trip_stop
    SET status           = 'cancelled',
        actual_arrival   = NULL,
        actual_departure = NULL
    WHERE trip_id = p_trip_id AND status <> 'cancelled'; -- обновляю у всех остановок, у которых статус != cancelled

    --Оформляется запись оперативного распоряжения
    o_order_number := 'OO-CNL-' || p_trip_id || '-'
                    || to_char(clock_timestamp(), 'YYMMDDHH24MISS');

    INSERT INTO Operational_order (
        responsible_id, number, issue_datetime,
        period_start, period_end, content, reason, status
    ) VALUES (
        p_responsible_id, o_order_number, clock_timestamp(),
        v_trip.trip_date, v_trip.trip_date,
        'Отмена рейса ' || COALESCE(v_trip.number, p_trip_id::text),
        p_reason, 'active'
    ) RETURNING order_id INTO v_order_id;

    -- Запись в связку рейс-распоряжение
    INSERT INTO Order_trip (order_id, trip_id) VALUES (v_order_id, p_trip_id);

    RAISE NOTICE 'Рейс % отменён. Распоряжение: %', p_trip_id, o_order_number;
END;
$$;

COMMIT;



-- Пример успешной отмены
BEGIN;

CALL cancel_trip(101, 'Технический сбой', 2, NULL);

SELECT stop_id, status, actual_arrival, actual_departure
FROM Trip_stop WHERE trip_id = 101 ORDER BY stop_id;

SELECT * FROM Operational_order WHERE number LIKE 'OO-CNL-101-%';
SELECT * FROM Order_trip ot
JOIN Operational_order oo USING (order_id)
WHERE oo.number LIKE 'OO-CNL-101-%';

ROLLBACK;




-- Пример ошибки (уже отменен рейс)
BEGIN;

CALL cancel_trip(101, 'x', 2, NULL);   -- успех
CALL cancel_trip(101, 'x', 2, NULL);   -- ERROR: Рейс 101 уже отменён
-- Транзакция теперь в состоянии «aborted» — только ROLLBACK/ROLLBACK TO SAVEPOINT

ROLLBACK;



-- Пример рейс не найден
BEGIN;
CALL cancel_trip(999, 'x', 2, NULL);   -- Рейс 999 не найден
ROLLBACK;

BEGIN;
CALL cancel_trip(102, 'x', 999, NULL); -- Ответственный 999 не найден
ROLLBACK;





-- Ошибка если у рейса уже есть первая неотмененная остановка
BEGIN;
UPDATE Trip_stop
SET status = 'on_schedule',
    actual_arrival = NULL,
    actual_departure = NULL
WHERE trip_id = 1;

UPDATE Trip_stop
SET status = 'completed',
    actual_arrival = COALESCE(actual_arrival, planned_arrival),
    actual_departure = COALESCE(actual_departure,
                                planned_departure,
                                planned_arrival + INTERVAL '2 minute')
WHERE stop_id = (
    SELECT stop_id FROM Trip_stop
    WHERE trip_id = 1
    ORDER BY planned_arrival NULLS LAST, stop_id
    LIMIT 1
);

CALL public.cancel_trip(1, 'Проверка: рейс уже в пути', 2, NULL);
ROLLBACK;

















CREATE OR REPLACE PROCEDURE shorten_trip(
    IN  p_trip_id          INTEGER,
    IN  p_station_id       INTEGER,
    IN  p_reason           TEXT,
    IN  p_responsible_id   INTEGER,
    OUT o_cancelled_count  INTEGER,
    OUT o_order_number     VARCHAR
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_trip          RECORD; -- рейс
    v_target        RECORD; -- целевая остановка
    v_end           RECORD; -- новая конечка
    v_total         INT; -- все остановки рейса включая отмененные
    v_active        INT; -- неотмененные остановки
    v_completed     INT; -- колво остановок со статусом completed
    v_tail          INT; -- сколько всего остаовок в хвосте
    v_tail_touched  INT; -- сколько из них уже со статусом completed
    v_order_id      INT; -- для созданнного оперативного распоряжения
BEGIN
    -- проверка что рейс существует
    SELECT * INTO v_trip
    FROM Trip
    WHERE trip_id = p_trip_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Error: Рейс % не найден', p_trip_id;
    END IF;

    -- проверка что ответственный существует
    PERFORM 1
    FROM Responsible
    WHERE responsible_id = p_responsible_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Error: Ответственный сотрудник % не найден', p_responsible_id;
    END IF;

    -- проверка состояния рейса
    SELECT COUNT(*),
           COUNT(*) FILTER (WHERE status <> 'cancelled'),
           COUNT(*) FILTER (WHERE status =  'completed')
    INTO v_total, v_active, v_completed
    FROM Trip_stop
    WHERE trip_id = p_trip_id;
    IF v_total = 0 THEN
        RAISE EXCEPTION 'Error: У рейса % нет остановок', p_trip_id;
    END IF;
    IF v_active = 0 THEN
        RAISE EXCEPTION 'Error: Рейс % уже отменен', p_trip_id;
    END IF;
    IF v_active = v_completed THEN
        RAISE EXCEPTION 'Error: Рейс % уже завершен', p_trip_id;
    END IF;

    -- Проверка что станция среди неотмененных остановок рейса
    SELECT o.stop_id, o.rn, o.actual_departure
    INTO v_target
    FROM (
        SELECT ts.stop_id, ts.station_id, ts.actual_departure,
               row_number() OVER (ORDER BY ts.planned_arrival NULLS LAST, ts.stop_id) AS rn
        FROM Trip_stop ts
        WHERE ts.trip_id = p_trip_id AND ts.status <> 'cancelled'
    ) o
    WHERE o.station_id = p_station_id
    ORDER BY o.rn
    LIMIT 1;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Error: Станция % не входит в неотмененные остановки рейса %',
            p_station_id, p_trip_id;
    END IF;

    -- С этой остановки поезд уже не должен уезжать, поэтому у него не должно быть actual_departure
    IF v_target.actual_departure IS NOT NULL THEN
        RAISE EXCEPTION
            'Error: Нельзя закончить рейс % на станции %: поезд уже отправился с неё (stop_id=%, %)',
            p_trip_id, p_station_id, v_target.stop_id, v_target.actual_departure;
    END IF;

    -- Проверка остановок, которые идут дальше по маршруту
    SELECT COUNT(*),
           COUNT(*) FILTER (WHERE o.status = 'completed' -- ищем остановки после текущей, которые уже выполнились
                               OR o.actual_arrival   IS NOT NULL
                               OR o.actual_departure IS NOT NULL)
    INTO v_tail, v_tail_touched
    FROM (
        SELECT ts.status, ts.actual_arrival, ts.actual_departure,
               row_number() OVER (ORDER BY ts.planned_arrival NULLS LAST, ts.stop_id) AS rn
        FROM Trip_stop ts
        WHERE ts.trip_id = p_trip_id AND ts.status <> 'cancelled'
    ) o
    WHERE o.rn > v_target.rn; -- для этого я и делал row_number. Чтобы потом сравнить номер станции с той станцией, на которой мы хотим остановиться
    IF v_tail = 0 THEN
        RAISE EXCEPTION
            'Error: Станция % уже является конечной для рейса % — укорачивать нечего',
            p_station_id, p_trip_id;
    END IF;
    IF v_tail_touched > 0 THEN
        RAISE EXCEPTION
            'Error: Нельзя укоротить рейс % до станции %: остановки дальше по маршруту уже выполнялись',
            p_trip_id, p_station_id;
    END IF;

    -- А потом уже отмена всех неотмененных остановок после целевой
    UPDATE Trip_stop
    SET status           = 'cancelled', -- обновляем статус
        actual_arrival   = NULL,
        actual_departure = NULL
    WHERE trip_id = p_trip_id
      AND status <> 'cancelled'
      AND stop_id IN (
          SELECT o.stop_id
          FROM (
              SELECT ts.stop_id,
                     row_number() OVER (ORDER BY ts.planned_arrival NULLS LAST, ts.stop_id) AS rn
              FROM Trip_stop ts
              WHERE ts.trip_id = p_trip_id AND ts.status <> 'cancelled'
          ) o
          WHERE o.rn > v_target.rn
      );
    GET DIAGNOSTICS o_cancelled_count = ROW_COUNT;

    -- Потом новая конечная - последняя из оставшихся неотмененных
    SELECT ts.stop_id, st.name AS station_name
    INTO v_end
    FROM Trip_stop ts
    JOIN Station st ON st.station_id = ts.station_id
    WHERE ts.trip_id = p_trip_id AND ts.status <> 'cancelled'
    ORDER BY ts.planned_arrival DESC NULLS FIRST, ts.stop_id DESC
    LIMIT 1; -- если станция заходит несклько раз на одном рейсе

    -- Потом создаем новое оперативное распоряжение
    o_order_number := 'OO-SHT-' || p_trip_id || '-'
                    || to_char(clock_timestamp(), 'YYMMDDHH24MISS');

    INSERT INTO Operational_order (
        responsible_id, number, issue_datetime,
        period_start, period_end, content, reason, status
    ) VALUES (
        p_responsible_id, o_order_number, clock_timestamp(),
        v_trip.trip_date, v_trip.trip_date,
        'Укорочение рейса ' || COALESCE(v_trip.number, p_trip_id::text)
            || ': новая конечная станция ' || v_end.station_name
            || ' (stop_id=' || v_end.stop_id
            || '), отменено остановок: ' || o_cancelled_count,
        p_reason, 'active'
    ) RETURNING order_id INTO v_order_id;

    INSERT INTO Order_trip    (order_id, trip_id)    VALUES (v_order_id, p_trip_id);
    INSERT INTO Order_station (order_id, station_id) VALUES (v_order_id, p_station_id);

    RAISE NOTICE 'Рейс %: отменено остановок %, новая конечная: %. Распоряжение: %',
        p_trip_id, o_cancelled_count, v_end.station_name, o_order_number;
END;
$$;

COMMIT;



-- Пример успешной отмены несколькоих остановок
BEGIN;

CREATE TEMP TABLE tmp_result (cancelled_count INT, order_number VARCHAR) ON COMMIT DROP;

DO $$
DECLARE
    v_trip_id INT; v_station INT; v_cnt INT; v_num VARCHAR;
BEGIN
    SELECT trip_id INTO v_trip_id FROM Trip WHERE number = 'TRP-P0001';
    SELECT station_id INTO v_station FROM Trip_stop
    WHERE trip_id = v_trip_id ORDER BY planned_arrival, stop_id OFFSET 2 LIMIT 1;

    CALL shorten_trip(v_trip_id, v_station, 'Затор на перегоне', 2, v_cnt, v_num);
    INSERT INTO tmp_result VALUES (v_cnt, v_num);
END;
$$;

SELECT * FROM tmp_result;   -- сколько отменено и номер распоряжения

SELECT stop_id, station_id, status, planned_arrival, actual_arrival, actual_departure
FROM Trip_stop
WHERE trip_id = (SELECT trip_id FROM Trip WHERE number = 'TRP-P0001')
ORDER BY planned_arrival, stop_id;

SELECT oo.* FROM Operational_order oo
WHERE oo.number = (SELECT order_number FROM tmp_result);

ROLLBACK;



-- примеры ошибок
DO $$
DECLARE
    v_cnt INT; v_num VARCHAR;
    v_trip INT; v_st INT; v_other INT;
BEGIN
    -- Нет рейса
    BEGIN
        CALL shorten_trip(999999, 1, 'x', 2, v_cnt, v_num);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE '[1] %', SQLERRM; END;

    -- Нет такого ответственного
    BEGIN
        SELECT trip_id INTO v_trip FROM Trip WHERE number = 'TRP-P0001';
        CALL shorten_trip(v_trip, 1, 'x', 999, v_cnt, v_num);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE '[2] %', SQLERRM; END;

    -- Станции нет в маршруте рейса
    BEGIN
        SELECT trip_id INTO v_trip FROM Trip WHERE number = 'TRP-P0013';
        SELECT s.station_id INTO v_other FROM Station s
        WHERE NOT EXISTS (SELECT 1 FROM Trip_stop ts
                          WHERE ts.trip_id = v_trip AND ts.station_id = s.station_id)
        LIMIT 1;
        CALL shorten_trip(v_trip, v_other, 'x', 2, v_cnt, v_num);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE '[3] %', SQLERRM; END;

    -- Остановка на этой станции уже отменнена
    BEGIN
        SELECT t.trip_id, ts.station_id INTO v_trip, v_st
        FROM Trip t JOIN Trip_stop ts USING (trip_id)
        WHERE t.number = 'TRP-P0017' AND ts.status = 'cancelled';
        CALL shorten_trip(v_trip, v_st, 'x', 2, v_cnt, v_num);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE '[4] %', SQLERRM; END;

    -- Рейс уже полнотью отменен)
    BEGIN
        SELECT t.trip_id, ts.station_id INTO v_trip, v_st
        FROM Trip t JOIN Trip_stop ts USING (trip_id)
        WHERE t.number = 'TRP-P0020' ORDER BY ts.stop_id LIMIT 1;
        CALL shorten_trip(v_trip, v_st, 'x', 2, v_cnt, v_num);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE '[5] %', SQLERRM; END;

    --(P0016) Рейс уже завершенн
    BEGIN
        SELECT t.trip_id, ts.station_id INTO v_trip, v_st
        FROM Trip t JOIN Trip_stop ts USING (trip_id)
        WHERE t.number = 'TRP-P0016' ORDER BY ts.stop_id LIMIT 1;
        CALL shorten_trip(v_trip, v_st, 'x', 2, v_cnt, v_num);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE '[6] %', SQLERRM; END;

    -- Станция уже конечка
    BEGIN
        SELECT t.trip_id INTO v_trip FROM Trip t WHERE t.number = 'TRP-P0013';
        SELECT station_id INTO v_st FROM Trip_stop
        WHERE trip_id = v_trip ORDER BY planned_arrival DESC, stop_id DESC LIMIT 1;
        CALL shorten_trip(v_trip, v_st, 'x', 2, v_cnt, v_num);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE '[7] %', SQLERRM; END;

    -- Поезд уже отправился с этой станции
    BEGIN
        SELECT t.trip_id INTO v_trip FROM Trip t WHERE t.number = 'TRP-P0001';
        SELECT station_id INTO v_st FROM Trip_stop
        WHERE trip_id = v_trip ORDER BY planned_arrival, stop_id LIMIT 1;
        CALL shorten_trip(v_trip, v_st, 'x', 2, v_cnt, v_num);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE '[8] %', SQLERRM; END;
END;
$$;
