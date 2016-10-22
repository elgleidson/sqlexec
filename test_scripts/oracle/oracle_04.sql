begin
  dbms_lock.sleep(2);
  raise_application_error(-20000, 'teste');
end;
/