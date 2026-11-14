CREATE OR REPLACE FUNCTION check_train_composition()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
    DECLARE
        v_unit_status unit_status;
        v_train_status train_status;
        v_period_start TIMESTAMP;
        v_period_end TIMESTAMP;
    BEGIN
        IF NEW.start_date IS NULL THEN RAISE EXCEPTION 'Error: Дата начала включения единицы в состав не указана'; END IF;
        IF NEW.end_date IS NOT NULL
            AND NEW.end_date < NEW.start_date THEN RAISE EXCEPTION 'Error: Дата окончания включения раньше даты начала'; END IF;

        SELECT
            t.status
        INTO v_train_status
        FROM Train t
        WHERE t.train_id = NEW.train_id;
        IF NOT FOUND THEN RAISE EXCEPTION 'Error: Состав % не существует', NEW.train_id; END IF;
        IF v_train_status <> 'formed' THEN RAISE EXCEPTION 'Error: состав % расформирован', NEW.train_id; END IF;

        -- Проверка подвижной единицы
        SELECT
            u.status
        INTO v_unit_status
        FROM rolling_unit u
        WHERE u.unit_id = NEW.unit_id;
        IF NOT FOUND THEN RAISE EXCEPTION 'Error: Подвижной единицы % нет', NEW.unit_id; END IF;
        IF v_unit_status NOT IN ('available', 'in_train')
            THEN RAISE EXCEPTION 'Error: Единицу % нельзя включить в состав: статус %', NEW.unit_id, v_unit_status; END IF;

        -- Поиск включений в другой действующий состав
        IF EXISTS(
            SELECT 1
            FROM Train_composition tc
            JOIN Train t ON t.train_id = tc.train_id
            WHERE tc.unit_id = NEW.unit_id AND tc.train_id <> NEW.train_id AND t.status = 'formed' -- ищем ток сформированные
                AND tc.start_date <= COALESCE(NEW.end_date, 'infinity'::DATE) -- конец нового позже, чем начало старого
                AND NEW.start_date <= COALESCE(tc.end_date, 'infinity'::DATE) -- новое начало раньше, чем конец старого
                -- не пересекаются когда:
                    -- 1. tc.end_date < NEW.start_date - старый полностью закончился до начала нового
                    -- 2. NEW.end_date < tc.start_date - новый полностью закончился до начала старого
                -- то есть пересечение есть когда ни один из этих случаев не выполняется

                -- При UPDATE исключаем старую версию этой строки
                AND (
                    TG_OP = 'INSERT'
                    OR ROW (tc.start_date, tc.train_id, tc.unit_id) IS DISTINCT FROM ROW (OLD.start_date, OLD.train_id, OLD.unit_id) -- тута при UPDATE
                    -- ROW - объединение трех значений для того чтобы вместе сравнить
                    -- IS DISTINCT FROM - проверка отличаются ли значения
                )
        )
        THEN RAISE EXCEPTION 'Error: Единица % уже включена в другой действующий состав на этот период', NEW.unit_id; END IF;

        -- 10-12 дек = [10 дек 00:00, 12 дек 00:00]
        v_period_start := NEW.start_date::TIMESTAMP;
        v_period_end := CASE
            WHEN NEW.end_date IS NULL THEN 'infinity'::TIMESTAMP
            ELSE NEW.end_date::TIMESTAMP + INTERVAL '1 day'
        END;

        -- проверка пересечения с ТО
        IF EXISTS (
            SELECT 1
            FROM Maintenance m
            WHERE m.unit_id = NEW.unit_id AND m.status IN ('planned', 'in_progress')
                AND m.start_date < v_period_end -- дата начала ТО раньше конца периода включения
                AND COALESCE(m.end_date, 'infinity'::TIMESTAMP) >= v_period_start -- дата окончания ТО позже, чем дата начала включения
        ) THEN
        RAISE EXCEPTION
            'Error" Единица % недоступна: период пересекается с техническим обслуживанием', NEW.unit_id;
        END IF;
    RETURN NEW; -- NEW содержит все значения, которые должны попасть в таблицу
    END;
$$;
-- Тут создание самого триггера, который вызывает триггерную функцию
-- Триггер закрепляется у таблицы Train_composition
DROP TRIGGER IF EXISTS trig_check_train_composition
ON Train_composition;

CREATE TRIGGER trig_check_train_composition
BEFORE INSERT OR UPDATE -- триггерная функция вызывается перед вставкой или обновлением строки
ON Train_composition -- таблица, изменения которой запускают триггер
FOR EACH ROW -- для каждой затронутой строки отдельно.
-- (если INSERT добавляет пять строк, функция вызывается пять раз и при каждом вызове NEW содержит соответствующую строку)
EXECUTE FUNCTION check_train_composition();





CREATE OR REPLACE FUNCTION check_crew_assignment()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
    DECLARE
        v_required_pass pass_type;
    BEGIN
        IF NEW.status = 'cancelled' THEN RETURN NEW; END IF;

        -- проверка интервала назначения
        IF NEW.start_date IS NULL OR NEW.end_date IS NULL
            THEN RAISE EXCEPTION 'Error: Для назначения сотрудника необходимо указать начало и конец';
        END IF;

        IF NEW.end_date <= NEW.start_date THEN RAISE EXCEPTION 'Error: Окончание назначения должно быть позже начала'; END IF;

        -- определение допуска по роли в бригаде
        CASE NEW.role
            WHEN 'driver' THEN
                v_required_pass := 'train_operation';

            WHEN 'assistant_driver' THEN
                v_required_pass := 'train_operation';

            WHEN 'conductor' THEN
                v_required_pass := 'passenger_service';

            WHEN 'brigadier' THEN
                v_required_pass := 'passenger_service';

            ELSE
                RAISE EXCEPTION 'Не определён необходимый допуск для роли %', NEW.role;
        END CASE;

        -- проверка что допуск покрывает значение целиком
        IF NOT EXISTS (
            SELECT 1
            FROM Employee_pass ep
            WHERE ep.employee_id = NEW.employee_id
              AND ep.pass_type = v_required_pass
              AND ep.status = 'valid'
              AND ep.issue_date::TIMESTAMP <= NEW.start_date
              AND ep.expiry_date::TIMESTAMP + INTERVAL '1 day' >= NEW.end_date
            ) THEN
                RAISE EXCEPTION 'Error: У сотрудника % нет действующего допуска % на весь период назначения', NEW.employee_id, v_required_pass;
        END IF;

        -- пересечение с другим неотмен мназначением
        IF EXISTS (
            SELECT 1
            FROM Crew_assignment ca
            WHERE ca.employee_id = NEW.employee_id AND ca.status <> 'cancelled'

                AND COALESCE(ca.start_date, '-infinity'::TIMESTAMP) < NEW.end_date
                AND NEW.start_date < COALESCE(ca.end_date, 'infinity'::TIMESTAMP)

                -- исключаем обновляемую запись по старому ключу
                AND (
                    TG_OP = 'INSERT'
                    OR
                    ROW( ca.assign_datetime, ca.employee_id, ca.trip_id )
                    IS DISTINCT FROM
                    ROW( OLD.assign_datetime, OLD.employee_id, OLD.trip_id )
                )
        ) THEN
            RAISE EXCEPTION
                'Error: У сотрудника % уже есть назначение на пересекающийся период', NEW.employee_id;
        END IF;


    RETURN NEW;
    END;
$$;
DROP TRIGGER IF EXISTS trig_check_crew_assignment
ON Crew_assignment;

CREATE TRIGGER trig_check_crew_assignment
BEFORE INSERT OR UPDATE
ON Crew_assignment
FOR EACH ROW
EXECUTE FUNCTION check_crew_assignment();
