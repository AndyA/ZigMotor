CREATE OR REPLACE TABLE digital AS from 'electronics/digital.csv';

CREATE OR REPLACE VIEW step_edges AS
SELECT
  "Time [s]" AS time,
  "STEP / MODE3" AS step,
  lag ("STEP / MODE3", 1, 0) OVER ( ORDER BY time ) AS prev
FROM
  digital;

CREATE OR REPLACE VIEW step_times AS
SELECT time FROM step_edges
WHERE step = 1 AND step != prev AND time >= 0;

CREATE OR REPLACE VIEW step_delta AS
SELECT time, time - lag (time, 1, 0) OVER ( ORDER BY time ) AS delta
FROM step_times;

CREATE OR REPLACE VIEW step_rate AS
SELECT time, 1 / delta AS rate
FROM step_delta
WHERE time > 0.000707083;

SET VARIABLE max_time = ( SELECT MAX(time) FROM step_rate );

CREATE OR REPLACE VIEW centiseconds AS
SELECT range / 100 AS time
FROM RANGE( 0, cast(getvariable ('max_time') * 100 + 2 as integer) );

CREATE OR REPLACE VIEW rpm AS
SELECT cs.time, sr.rate / 3200 * 60 as rpm
FROM centiseconds cs ASOF JOIN step_rate sr ON cs.time >= sr.time;

COPY ( FROM rpm ORDER BY time ) TO 'rpm.csv';