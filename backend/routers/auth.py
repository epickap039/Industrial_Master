"""API router: login."""
from fastapi import APIRouter, HTTPException

from auth_service import hash_password
from database import get_db_connection
from jwt_tokens import create_access_token
from models import LoginRequest

router = APIRouter()

@router.post("/api/login")
def login(request: LoginRequest):
    try:
        conn = get_db_connection()
        cursor = conn.cursor()
        
        hashed_password = hash_password(request.password)
        cursor.execute("SELECT rol FROM Tbl_Usuarios WHERE username = ? AND password_hash = ?", (request.username, hashed_password))
        user = cursor.fetchone()
        
        conn.close()
        
        if user:
            username = (request.username or "").strip()
            rol = user[0] or "USER"
            token = create_access_token(username, str(rol))
            return {"success": True, "rol": rol, "access_token": token}
        else:
            from fastapi import HTTPException
            raise HTTPException(status_code=401, detail="Credenciales incorrectas")
            
    except Exception as e:
        print(f"Error en login: {e}")
        from fastapi import HTTPException
        raise HTTPException(status_code=500, detail="Error interno del servidor")
