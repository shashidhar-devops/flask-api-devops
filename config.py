import os
from dotenv import load_dotenv

load_dotenv(override=False)

class Config:
    DEBUG = os.getenv('DEBUG', 'False') == 'True'
    SQLALCHEMY_DATABASE_URI = (
        f"postgresql://{os.getenv('POSTGRES_USER', 'user')}"
        f":{os.getenv('POSTGRES_PASSWORD', 'password')}"
        f"@{os.getenv('POSTGRES_HOST', 'localhost')}"
        f":{os.getenv('POSTGRES_PORT', '5432')}"
        f"/{os.getenv('POSTGRES_DB', 'dbname')}"
    )
    SQLALCHEMY_TRACK_MODIFICATIONS = False
