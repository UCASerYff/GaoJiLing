class AppError(Exception):
    """可直接展示给使用者的本地错误。不包含栈或内部路径以外的诊断。"""

    def __init__(self, message: str):
        super().__init__(message)
        self.message = message
