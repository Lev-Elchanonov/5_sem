-- стат. данные рейса + данные о первой и посдней остановке
CREATE OR REPLACE TEMP VIEW report_trips AS
SELECT t.trip_id, t.trip_date, t.train_id, s.scheme_id, ls.line_id,
       f.station_id AS origin_id, z.station_id AS destinatin_id,
       f.actual_departure AS departed_at, z.actual_arrival AS arrived_at,
       EXTRACT(EPOCH FROM f.actual_departure - f.planned_departure) / 60 AS departure_min,
       EXTRACT(EPOCH FROM z.actual_arrival - z.planned_arrival) / 60 AS arrival_min,
       CASE
           WHEN f.stop_id IS NULL AND EXISTS(
               SELECT 1 FROM Trip_stop x WHERE x.trip_id = t.trip_id
           ) THEN 'cancelled'
            WHEN f.actual_departure IS NOT NULL AND z.actual_arrival IS NOT NULL
                THEN 'completed'
            WHEN f.actual_departure IS NOT NULL THEN 'in_progress'
            ELSE 'unknown:D'
        END AS trip_status
FROM trip t
JOIN Schedule s ON s.scheme_id = t.schedule_id
JOIN Line_scheme ls ON ls.scheme_id = s.scheme_id
LEFT JOIN LATERAL( -- Lateral позволяет ссылаться на таблицы что слева
    SELECT *
    FROM Trip_stop x
    WHERE x.trip_id = t.trip_id AND x.status <> 'cancelled'
    ORDER BY COALESCE(x.planned_arrival, x.planned_departure) ASC NULLS LAST, x.stop_id
    LIMIT 1
) f ON true -- тут данные первой остановки
LEFT JOIN LATERAL (
    SELECT *
    FROM Trip_stop x
    WHERE x.trip_id = t.trip_id AND x.status <> 'cancelled'
    ORDER BY COALESCE(x.planned_arrival, x.planned_departure) DESC NULLS LAST, x.stop_id DESC
    LIMIT 1
) z ON true; -- тут данные последней остановки

-- крч отдельно надо было создать таблицу связи распоряжение с участком
CREATE TEMP TABLE IF NOT EXISTS report_order_segment (
    order_id integer,
    segment_id integer,
    PRIMARY KEY (order_id, segment_id)
);

--1. Сводка по линиям за 2025 год
WITH trips AS (
    SELECT *
    FROM report_trips
    WHERE trip_date >= DATE '2025-01-01' AND trip_date < DATE '2026-01-01'
),
trip_stats AS (
    SELECT line_id, COUNT(DISTINCT scheme_id) AS schemes_used,
    COUNT(*) AS trips,
    COUNT(*) FILTER (WHERE trip_status = 'completed') AS completed,
    COUNT(*) FILTER (WHERE trip_status = 'cancelled') AS cancelled,
    COUNT(*) FILTER (WHERE trip_status = 'in_progress') AS in_progress,
    AVG(departure_min) FILTER (WHERE trip_status <> 'cancelled') AS departure_min,
    AVG(arrival_min) FILTER (WHERE trip_status = 'completed') AS arrival_min
    FROM trips
    GROUP BY line_id
),
line_stations AS (
    SELECT line_id, station_begin AS station_id FROM Line_segment
    UNION -- объединение первой и второй выборки + удаленине дубликатов
    SELECT line_id, station_end FROM Line_segment
),
order_links AS (
    SELECT line_id, order_id FROM Order_line
    UNION
    SELECT ls.line_id, os.order_id
    FROM Order_station os JOIN line_stations ls USING (station_id) -- по станциям
    UNION
    SELECT ls.line_id, ot.order_id
    FROM Order_trip ot -- по рейсам
    JOIN Trip t USING (trip_id)
    JOIN Schedule s USING (schedule_id)
    JOIN Line_scheme ls USING (scheme_id)
    UNION
    SELECT ls.line_id, os.order_id
    FROM report_order_segment os JOIN Line_segment ls USING (segment_id) -- через участок
),
order_stats AS (
    SELECT ol.line_id, COUNT(*) AS orders
    FROM order_links ol JOIN Operational_order o USING (order_id)
    WHERE o.issue_datetime >= TIMESTAMP '2025-01-01'
    AND o.issue_datetime < TIMESTAMP '2026-01-01'
    GROUP BY ol.line_id
),
trip_units AS (
    SELECT DISTINCT t.trip_id, t.line_id, t.trip_date, c.unit_id
    FROM trips t
    JOIN train_composition c USING (train_id)
    WHERE t.trip_status <> 'cancelled'
        AND t.trip_date >= c.start_date
        AND (c.end_date IS NULL OR t.trip_date <= c.end_date)
),
incident_links AS (
    SELECT t.line_id, i.incident_id
    FROM Incident i JOIN trips t USING (trip_id) -- по рейсам
    UNION
    SELECT ls.line_id, i.incident_id
    FROM Incident i JOIN line_stations ls USING (station_id) -- по стациям
    UNION
    SELECT ls.line_id, i.incident_id
    FROM Incident i JOIN Line_segment ls USING (segment_id) -- по сегментам
    UNION
    SELECT t.line_id, i.incident_id
    FROM Incident i JOIN trips t USING (train_id)
    WHERE t.trip_status <> 'cancelled' AND t.trip_date = i.event_datetime::date
    UNION
    SELECT u.line_id, i.incident_id
    FROM Incident i JOIN trip_units u USING (unit_id) -- на подв. единицах
    WHERE u.trip_date = i.event_datetime::date
),
incident_stats AS (
    SELECT il.line_id, COUNT(*) AS incidents
    FROM incident_links il JOIN Incident i USING (incident_id)
    WHERE i.event_datetime >= TIMESTAMP '2025-01-01'
        AND i.event_datetime < TIMESTAMP '2026-01-01'
    GROUP BY il.line_id
),
maintenance_stats AS (
    SELECT u.line_id,
           SUM (EXTRACT(EPOCH FROM
                LEAST(m.end_date, TIMESTAMP '2026-01-01') -
                GREATEST(m.start_date, TIMESTAMP '2025-01-01')) / 3600) AS hours
    FROM (SELECT DISTINCT line_id, unit_id FROM trip_units) u
    JOIN Maintenance m USING (unit_id)
    WHERE m.status <> 'cancelled'
        AND m.start_date < TIMESTAMP '2026-01-01'
        AND m.end_date > TIMESTAMP '2025-01-01'
    GROUP BY u.line_id
)
SELECT l.line_id, l.name, l.description, l.commissioning_date, l.status,
       COALESCE(t.schemes_used, 0) AS schemes_used,
       COALESCE(t.trips, 0) AS trips,
       COALESCE(t.completed, 0) AS completed,
       COALESCE(t.cancelled, 0) AS cancelled,
       COALESCE(t.in_progress, 0) AS in_progress,
       ROUND(100.0 * t.cancelled/ NULLIF(t.trips, 0), 2) AS cancelled_pct,
       ROUND(t.departure_min, 2) AS avg_departure_min,
       ROUND(t.arrival_min, 2) AS avg_arrival_min,
       COALESCE(o.orders, 0) AS orders,
       COALESCE(i.incidents, 0) AS incidents,
       ROUND(COALESCE(m.hours, 0), 2) AS maintain_hours
FROM Line l
LEFT JOIN trip_stats t USING (line_id)
LEFT JOIN order_stats o USING (line_id)
LEFT JOIN incident_stats i USING (line_id)
LEFT JOIN maintenance_stats m USING (line_id)
ORDER BY t.departure_min DESC NULLS LAST, l.line_id;




--2. Отчет по станциям за 1ый квартал 2025 года
WITH stops AS (
    SElECT x.station_id, x.status, t.line_id,
           EXTRACT(EPOCH FROM x.actual_arrival - x.planned_arrival) / 60 AS arrival_min,
           EXTRACT(EPOCH FROM x.actual_departure - x.planned_departure) / 60 AS departure_min
    FROM report_trips t
    JOIN Trip_stop x USING (trip_id)
    WHERE t.trip_date >= DATE '2025-01-01' AND t.trip_date < DATE '2025-04-01'
        AND t.trip_status <> 'cancelled'
),
stop_stats AS (
    SELECT station_id,
           COUNT(*) FILTER (WHERE status <> 'cancelled') AS stops,
           COUNT(*) FILTER (WHERE status = 'cancelled') AS cancelled_stops,
           COUNT(*) FILTER (WHERE status <> 'cancelled' AND arrival_min > 5) AS late_arrivals,
           COUNt(*) FILTER (WHERE status <> 'cancelled' AND departure_min > 5) AS late_departures,
           AVG(arrival_min) FILTER (WHERE status <> 'cancelled' AND arrival_min > 5) AS avg_arrival_min,
           AVG(departure_min) FILTER (WHERE status <> 'cancelled' AND departure_min > 5) AS avg_departure_min
    FROM stops
    GROUP BY station_id
),
top_line AS (
    SELECT DISTINCT ON (station_id) station_id, line_id
    FROM stops
    WHERE status <> 'cancelled' AND departure_min > 5
    GROUP BY station_id, line_id
    ORDER BY station_id, COUNT(*) DESC, line_id
),
order_stats AS (
    SELECT station_id, COUNT(*) AS orders
    FROM Order_station JOIN Operational_order USING(order_id)
    WHERE issue_datetime >= TIMESTAMP '2025-01-01'
        AND issue_datetime < TIMESTAMP '2025-04-01'
    GROUP BY station_id
),
incident_stats AS (
    SELECT station_id, MAX(event_datetime) AS last_incident
    FROM Incident
    WHERE station_id IS NOT NULL
      AND event_datetime >= TIMESTAMP '2025-01-01'
      AND event_datetime <  TIMESTAMP '2025-04-01'
    GROUP BY station_id
)
SELECT s.code, s.name, s.latitude, s.longitude, s.status,
       COALESCE(a.stops, 0) AS stops,
       COALESCE(a.late_arrivals, 0) AS late_arrivals,
       COALESCE(a.late_departures, 0) AS late_departures,
       ROUND(a.avg_arrival_min, 2) AS avg_arrival_min,
       ROUND(a.avg_departure_min, 2) AS avg_departure_min,
       COALESCE(a.cancelled_stops, 0) AS cancelled_stops,
       COALESCE(o.orders, 0) AS orders,
       l.name AS top_line, i.last_incident
FROM Station s
LEFT JOIN stop_stats a USING (station_id)
LEFT JOIN order_stats o USING(station_id)
LEFT JOIN incident_stats i USING(station_id)
LEFT JOIN top_line tl USING (station_id)
LEFT JOIN Line l ON l.line_id = tl.line_id
ORDER BY late_departures DESC, s.code;




--3. Отчет о периодах
WITH period AS (
    SELECT TIMESTAMP '2025-07-01' AS begins, TIMESTAMP '2026-01-01' AS ends
),
unit_trips AS(
    SELECT DISTINCT c.unit_id, t.trip_id,
                    EXTRACT(EPOCH FROM t.arrived_at - t.departed_at) / 3600 AS hours
    FROM report_trips t
    JOIN Train_composition c USING (train_id)
    CROSS JOIN period p
    WHERE t.trip_date >= p.begins AND t.trip_date < p.ends
        AND t.trip_status = 'completed'
        AND t.departed_at IS NOT NULL AND t.arrived_at IS NOT NULL
        AND t.trip_date >= c.start_date
        AND (c.end_date IS NULL OR t.trip_date <= c.end_date)
),
trip_stats AS (
    SELECT unit_id, COUNT(*) AS trips, SUM(hours) AS hours
    FROM unit_trips
    GROUP BY unit_id
),
train_stats AS (
    SELECT unit_id, COUNT(DISTINCT train_id) AS trains
    FROM Train_composition CROSS JOIN period
    WHERE start_date < ends AND (end_date IS NULL OR end_date >= begins)
    GROUP BY unit_id
),
maintenance_stats AS (
    SELECT m.unit_id, range_agg(tsrange(
                            GREATEST(m.start_date, p.begins), LEAST(m.end_date, p.ends)
                            )) AS periods
    FROM Maintenance m CROSS JOIN period p
    WHERE m.status <> 'cancelled' AND m.start_date < p.endS AND m.end_date > p.begins
    GROUP BY m.unit_id
),
maintenance_hours AS (
    SELECT unit_id, SUM(EXTRACT(EPOCH FROM upper(r.span) - lower(r.span)) / 3600) AS hours
    FROM maintenance_stats m CROSS JOIN LATERAL unnest(m.periods) AS r(span)
    GROUP BY unit_id
),
incident_stats AS (
    SELECT unit_id, COUNT(*) AS incidents, MAX(severity) AS max_severity
    FROM Incident CROSS JOIN period
    WHERE unit_id IS NOT NULL AND event_datetime >= begins AND event_datetime < ends
    GROUP BY unit_id
),
unit_stats AS (
    SELECT u.number, u.unit_type, u.model, u.manufacture_year, u.capacity, u.status,
           COALESCE(t.trips, 0) AS completed_trips,
           COALESCE(t.hours, 0) AS trip_hours,
           COALESCE(m.hours, 0) AS maintenance_hours,
           COALESCE(c.trains, 0) AS different_trains,
           COALESCE(i.incidents, 0) AS incidents, i.max_severity,
           CASE WHEN available.hours > 0
                THEN 100.0 * COALESCE(t.hours, 0) / available.hours END AS usage_pct
    FROM Rolling_unit u
    LEFT JOIN trip_stats t USING (unit_id)
    LEFT JOIN train_stats c USING (unit_id)
    LEFT JOIN maintenance_hours m USING (unit_id)
    LEFT JOIN incident_stats i USING (unit_id)
    CROSS JOIN period p
    CROSS JOIN LATERAL (
        SELECT EXTRACT(EPOCH FROM p.ends - p.begins) / 3600 - COALESCE(m.hours, 0) AS hours
    ) available
    WHERE t.trips >= 5 OR i.incidents > 0
)
SELECT number, unit_type, model, manufacture_year, capacity, status, completed_trips,
       ROUND(trip_hours, 2) AS trip_hours,
       ROUND(maintenance_hours, 2) AS maintenance_hours,
       different_trains, incidents, max_severity,
       ROUND(usage_pct, 2) AS usage_pct,
       RANK() OVER (PARTITION BY unit_type ORDER BY usage_pct DESC NULLS LAST) AS usage_rank
FROM unit_stats
ORDER BY unit_type, usage_rank, number;



--4. Статистика по месяцам за 2025
WITH months AS (
    SELECT generate_series(TIMESTAMP '2025-01-01', TIMESTAMP '2025-12-01',
           INTERVAL '1 month')::date AS month_start
),
trips AS (
    SELECT trip_id, trip_status, line_id, departure_min,
           date_trunc('month', trip_date::timestamp)::date AS month_start
    FROM report_trips
    WHERE trip_date >= DATE '2025-01-01' AND trip_date < DATE '2026-01-01'
),
trip_stats AS (
    SELECT month_start, COUNT(*) AS trips,
           COUNT(*) FILTER(WHERE trip_status = 'cancelled') AS cancelled,
           COUNT(*) FILTER(WHERE trip_status <> 'cancelled' AND departure_min > 5) AS late_departures,
           AVG(departure_min) FILTER(WHERE trip_status <> 'cancelled') AS avg_departure_min
    FROM trips
    GROUP BY month_start
),
stop_stats AS (
    SELECT t.month_start, COUNT(*) AS stops
    FROM trips t JOIN Trip_stop s USING (trip_id)
    WHERE t.trip_status <> 'cancelled' AND s.status <> 'cancelled'
    GROUP BY t.month_start
),
top_line AS (
    SELECT DISTINCT ON (month_start) month_start, line_id, COUNT(*) AS trips
    FROM trips
    GROUP BY month_start, line_id
    ORDER BY month_start, COUNT(*) DESC, line_id
),
order_stats AS (
    SELECT date_trunc('month', issue_datetime)::date AS month_start, COUNT(*) AS orders
    FROM Operational_order
    WHERE issue_datetime >= TIMESTAMP '2025-01-01'
        AND issue_datetime < TIMESTAMP '2026-01-01'
    GROUP BY month_start
),
incident_stats AS (
    SELECT date_trunc('month', event_datetime)::date AS month_start, COUNT(*) AS incidents
    FROM incident
    WHERE event_datetime >= TIMESTAMP '2025-01-01'
        AND event_datetime <  TIMESTAMP '2026-01-01'
    GROUP BY month_start
),
monthly AS (
    SELECT month_start, EXTRACT(MONTH FROM month_start)::int AS month_num,
           COALESCE(t.trips, 0) AS trips, COALESCE(t.cancelled, 0) AS cancelled,
           COALESCE(s.stops, 0) AS stops, COALESCE(t.late_departures) AS late_departures,
           l.name AS top_line, COALESCE(tl.trips, 0) AS top_line_trips,
           COALESCE(o.orders, 0) AS orders, COALESCE(i.incidents, 0) AS incidents,
           t.avg_departure_min,
           LAG(COALESCE(t.trips, 0)) OVER (ORDER BY month_start) AS previous_trips
    FROM months
    LEFT JOIN trip_stats t USING (month_start)
    LEFT JOIN stop_stats s USING (month_start)
    LEFT JOIN top_line tl USING (month_start)
    LEFT JOIN Line l USING (line_id)
    LEFT JOIN order_stats o USING (month_start)
    LEFT JOIN incident_stats i USING (month_start)
)
SELECT (ARRAY['Январь','Февраль','Март','Апрель','Май','Июнь',
              'Июль','Август','Сентябрь','Октябрь','Ноябрь','Декабрь'])[month_num] AS month_name,
       month_num, trips, cancelled,
       ROUND(100.0 * cancelled / NULLIF(trips, 0), 2) AS cancelled_pct,
       stops, late_departures, top_line, top_line_trips, orders, incidents,
       ROUND(100.0 * (trips - previous_trips) / NULLIF(previous_trips, 0), 2) AS change_pct,
       ROUND(avg_departure_min, 2) AS avg_departure_min
FROM monthly
ORDER BY month_num;



--5. Матрица отправлений за 1ое полугодье
WITH trip_counts AS (
    SELECT origin_id, destinatin_id, COUNT(*) AS trips
    FROM report_trips
    WHERE trip_date >= DATE '2025-01-01'
        AND trip_date < DATE '2025-07-01'
        AND trip_status = 'completed'
    GROUP BY origin_id, destinatin_id
)
SELECT o.name AS origin,
       d.name AS destination,
       COALESCE(t.trips, 0) AS trips
FROM Station o
CROSS JOIN Station d
LEFT JOIN trip_counts t
    ON t.origin_id = o.station_id
    AND t.destinatin_id = d.station_id
ORDER BY o.code, d.code
\crosstabview origin destination trips








