import os
from dotenv import load_dotenv

load_dotenv(override=False)

class Config:
    DEBUG = os.getenv('DEBUG', 'False') == 'True'

    POSTGRES_USER = os.getenv('POSTGRES_USER', 'user')
    POSTGRES_PASSWORD = os.getenv('POSTGRES_PASSWORD', 'password')
    POSTGRES_HOST = os.getenv('POSTGRES_HOST', 'localhost')
    POSTGRES_DB = os.getenv('POSTGRES_DB', 'dbname')
    POSTGRES_PORT = os.getenv('POSTGRES_PORT', '5432')

    SQLALCHEMY_DATABASE_URI = f"postgresql://{POSTGRES_USER}:{POSTGRES_PASSWORD}@{POSTGRES_HOST}:{POSTGRES_PORT}/{POSTGRES_DB}"
    SQLALCHEMY_TRACK_MODIFICATIONS = False
