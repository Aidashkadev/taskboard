import os


class Settings:
    app_name: str = "TaskBoard"
    # deploy.sh передаёт DATABASE_URL через переменную окружения;
    # значение по умолчанию сохраняет старое поведение для ручного запуска.
    database_url: str = os.getenv(
        "DATABASE_URL",
        "postgresql+psycopg://taskboard:taskboard@localhost:5432/taskboard",
    )


settings = Settings()
