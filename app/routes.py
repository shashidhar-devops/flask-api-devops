from flask import Blueprint, request, jsonify
from app.models import User

api = Blueprint('api', __name__)

@api.route('/users', methods=['POST'])
def create_user():
    from app import db
    data = request.get_json()
    user = User(username=data['username'], email=data['email'])
    db.session.add(user)
    db.session.commit()
    return jsonify(user.to_dict()), 201

@api.route('/users', methods=['GET'])
def get_users():
    users = User.query.all()
    return jsonify([user.to_dict() for user in users]), 200

@api.route('/users/<int:user_id>', methods=['GET'])
def get_user(user_id):
    from app import db
    user = db.session.get(User, user_id)
    if not user:
        return jsonify({'error': 'User not found'}), 404
    return jsonify(user.to_dict()), 200

@api.route('/users/<int:user_id>', methods=['DELETE'])
def delete_user(user_id):
    from app import db
    user = db.session.get(User, user_id)
    if not user:
        return jsonify({'error': 'User not found'}), 404
    db.session.delete(user)
    db.session.commit()
    return jsonify({'message': 'User deleted'}), 200
