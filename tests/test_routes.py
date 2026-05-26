import pytest
from app import create_app, db

@pytest.fixture
def client():
    app = create_app(testing=True)

    with app.app_context():
        db.create_all()
        yield app.test_client()
        db.drop_all()

def test_create_user(client):
    response = client.post('/users', json={
        'username': 'testuser',
        'email': 'test@example.com'
    })
    assert response.status_code == 201

def test_get_users(client):
    response = client.get('/users')
    assert response.status_code == 200

def test_get_user(client):
    client.post('/users', json={
        'username': 'testuser2',
        'email': 'test2@example.com'
    })
    response = client.get('/users/1')
    assert response.status_code == 200

def test_delete_user(client):
    client.post('/users', json={
        'username': 'testuser3',
        'email': 'test3@example.com'
    })
    response = client.delete('/users/1')
    assert response.status_code == 200
