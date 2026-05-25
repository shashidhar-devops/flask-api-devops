from flask import Flask
from flask_sqlalchemy import SQLAlchemy
from flask_migrate import Migrate
from config import Config

db = SQLAlchemy()
migrate = Migrate()

def create_app(testing=False):
    app = Flask(__name__)
    
    # 1. Load basic config
    app.config.from_object(Config)
    
    # 2. Overwrite for testing BEFORE initializing db
    if testing:
        app.config['SQLALCHEMY_DATABASE_URI'] = 'sqlite:///:memory:'
        app.config['SQLALCHEMY_ENGINE_OPTIONS'] = {} # Clear pool options
    
    # 3. Now initialize extensions
    db.init_app(app)
    
    if not testing:
        migrate.init_app(app, db)
        
    from app.routes import api
    app.register_blueprint(api)
    
    return app
