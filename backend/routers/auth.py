"""API router: login."""
from fastapi import APIRouter, HTTPException

from auth_service import hash_password
from database import get_db_connection
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
            return {"success": True, "rol": user[0]}
        else:
            from fastapi import HTTPException
            raise HTTPException(status_code=401, detail="Credenciales incorrectas")
            
    except Exception as e:
        print(f"Error en login: {e}")
        from fastapi import HTTPException
        raise HTTPException(status_code=500, detail="Error interno del servidor")
